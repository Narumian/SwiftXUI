import Foundation

/// The one buffer between a sample producer and the outputs that play it. The
/// producer pushes at its own pace; each output reads through its own `Reader`, on
/// its own clock, and never waits. A reader that finds the buffer empty is topped
/// up with blanked samples parked at its last position, so a starved output goes
/// dark instead of holding a lit point or repeating content.
///
/// The producer waits when the buffer is full for the reader that is furthest
/// ahead, so the buffer is paced by whichever output is consuming. A reader that
/// falls more than `capacity` behind (a link that stalled, say) is moved forward to
/// the oldest sample still kept: it loses that stretch, and the others never wait
/// for it.
public final class LaserSampleRing: @unchecked Sendable {
    public let capacity: Int
    private let lock = NSLock()
    private var storage: [LaserPoint]
    /// Samples ever written. A sample's index in `storage` is its number modulo `capacity`.
    private var written = 0
    /// Readers are held weakly: one that is dropped stops holding the producer up.
    private var readers: [ObjectIdentifier: WeakReader] = [:]
    private struct WeakReader { weak var reader: Reader? }
    private var live: [Reader] {
        readers = readers.filter { $0.value.reader != nil }
        return readers.values.compactMap(\.reader)
    }

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = Array(repeating: try! LaserPoint(xy: .zero, rgb: .zero, isBlanked: true), count: capacity)
    }

    /// One output's way of reading the ring. It starts at the live end.
    public final class Reader: @unchecked Sendable {
        fileprivate let ring: LaserSampleRing
        fileprivate var position: Int
        fileprivate var last: LaserPoint
        fileprivate var starved = 0
        fileprivate var starvedPulls = 0
        fileprivate var skipped = 0
        fileprivate init(ring: LaserSampleRing, position: Int) {
            self.ring = ring; self.position = position
            last = try! LaserPoint(xy: .zero, rgb: .zero, isBlanked: true)
        }

        /// Samples waiting for this reader.
        public var fill: Int { ring.lock.withLock { min(ring.capacity, ring.written - position) } }
        /// Samples invented because the producer was late.
        public var starvedSamples: Int { ring.lock.withLock { starved } }
        /// Pulls that needed at least one invented sample.
        public var starvedPullCount: Int { ring.lock.withLock { starvedPulls } }
        /// Samples lost because this reader fell too far behind.
        public var skippedSamples: Int { ring.lock.withLock { skipped } }

        /// Takes exactly `requested` samples, topping up with blanked samples at the
        /// last position when fewer are buffered. Never waits.
        public func pull(_ requested: Int) -> [LaserPoint] {
            guard requested > 0 else { return [] }
            return ring.lock.withLock {
                ring.catchUp(self)
                let available = min(requested, ring.written - position)
                var out: [LaserPoint] = []
                out.reserveCapacity(requested)
                for _ in 0..<available {
                    out.append(ring.storage[position % ring.capacity])
                    position += 1
                }
                if let tail = out.last { last = tail }
                if available < requested {
                    starved += requested - available
                    starvedPulls += 1
                    let dark = try! LaserPoint(xy: last.xy, rgb: .zero, isBlanked: true)
                    out.append(contentsOf: Array(repeating: dark, count: requested - available))
                    last = dark
                }
                return out
            }
        }
    }

    /// A new reader, starting at what is being written now.
    public func makeReader() -> Reader {
        lock.withLock {
            let reader = Reader(ring: self, position: written)
            readers[ObjectIdentifier(reader)] = WeakReader(reader: reader)
            return reader
        }
    }

    public func remove(_ reader: Reader) {
        lock.withLock { _ = readers.removeValue(forKey: ObjectIdentifier(reader)) }
    }

    public var readerCount: Int { lock.withLock { live.count } }

    /// Moves a reader that fell behind up to the oldest sample still kept.
    private func catchUp(_ reader: Reader) {
        let oldest = written - capacity
        if reader.position < oldest { reader.skipped += oldest - reader.position; reader.position = oldest }
    }

    /// Appends as many samples as fit and returns how many were taken. With no
    /// reader nothing is taken.
    public func tryPush(_ points: ArraySlice<LaserPoint>) -> Int {
        lock.withLock {
            guard let ahead = live.map(\.position).max() else { return 0 }
            let accepted = min(points.count, capacity - (written - max(ahead, written - capacity)))
            for point in points.prefix(accepted) {
                storage[written % capacity] = point
                written += 1
            }
            return accepted
        }
    }

    /// Appends all of `points`, suspending while the buffer is full. Throws when
    /// the calling task is cancelled.
    public func push(_ points: [LaserPoint]) async throws {
        var rest = points[...]
        while !rest.isEmpty {
            let taken = tryPush(rest)
            rest = rest.dropFirst(taken)
            if !rest.isEmpty { try await Task.sleep(nanoseconds: 2_000_000) }
        }
    }

    /// Drops everything buffered, e.g. when the source is replaced.
    public func clear() {
        lock.withLock { for reader in live { reader.position = written } }
    }
}

/// Converts a stream of samples from one point rate to another by linear
/// interpolation of position and colour. A sample between two blanked-or-lit
/// neighbours is blanked if either neighbour is, so conversion can only darken
/// the edge of a lit run, never light a travel move. Equal rates pass through
/// untouched. Geometry sampled this way is smoothed: corners dwelt on for a few
/// samples are rounded off when the rates differ.
public struct LaserRateConverter: Sendable {
    public let sourceRate: Double
    public let outputRate: Double
    private var current: LaserPoint?
    private var following: LaserPoint?
    private var phase = 0.0
    private var pending: [LaserPoint] = []
    private var pendingIndex = 0

    public init(sourceRate: UInt32, outputRate: UInt32) {
        precondition(sourceRate > 0 && outputRate > 0)
        self.sourceRate = Double(sourceRate)
        self.outputRate = Double(outputRate)
    }

    public var isPassthrough: Bool { sourceRate == outputRate }

    /// Produces `count` output samples, calling `pull` for the source samples it
    /// needs in chunks of `chunk`. `pull(n)` must return exactly `n` samples.
    public mutating func convert(count: Int, chunk: Int = 64, pull: (Int) -> [LaserPoint]) -> [LaserPoint] {
        guard count > 0 else { return [] }
        if isPassthrough { return pull(count) }
        let step = sourceRate / outputRate
        var out: [LaserPoint] = []
        out.reserveCapacity(count)
        func next() -> LaserPoint {
            if pendingIndex == pending.count {
                // Surplus beyond this call is kept for the next one, never dropped.
                pending = pull(chunk)
                pendingIndex = 0
            }
            defer { pendingIndex += 1 }
            return pending[pendingIndex]
        }
        if current == nil { current = next(); following = next() }
        for _ in 0..<count {
            out.append(Self.lerp(current!, following!, Float(phase)))
            phase += step
            while phase >= 1 {
                current = following
                following = next()
                phase -= 1
            }
        }
        return out
    }

    private static func lerp(_ a: LaserPoint, _ b: LaserPoint, _ t: Float) -> LaserPoint {
        if t == 0 { return a }
        func mix(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        let xy = SIMD2<Float>(min(1, max(-1, mix(a.xy.x, b.xy.x))), min(1, max(-1, mix(a.xy.y, b.xy.y))))
        let rgb = SIMD3<Float>(min(1, max(0, mix(a.rgb.x, b.rgb.x))), min(1, max(0, mix(a.rgb.y, b.rgb.y))), min(1, max(0, mix(a.rgb.z, b.rgb.z))))
        // A point between two others moves: dark if either end is dark, never a dwell.
        return try! LaserPoint(xy: xy, rgb: rgb, mode: a.isBlanked || b.isBlanked ? .blank : .normal)
    }
}
