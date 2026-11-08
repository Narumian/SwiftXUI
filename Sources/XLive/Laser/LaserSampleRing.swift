import Foundation

/// A bounded buffer between a sample producer and an output pump. The producer
/// pushes at its own pace and waits when the buffer is full; the pump pulls a
/// fixed count on the device's clock and never waits. If the producer is late the
/// pull is topped up with blanked samples parked at the last position, so a
/// starved output goes dark instead of holding a lit point or repeating content.
public final class LaserSampleRing: @unchecked Sendable {
    public let capacity: Int
    private let lock = NSLock()
    private var storage: [LaserPoint]
    private var head = 0
    private var count = 0
    private var last: LaserPoint
    private var starved = 0
    private var starvedPulls = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        last = try! LaserPoint(xy: .zero, rgb: .zero, isBlanked: true)
        storage = Array(repeating: last, count: capacity)
    }

    /// Samples currently buffered.
    public var fill: Int { lock.withLock { count } }
    /// Samples the pump had to invent because the producer was late.
    public var starvedSamples: Int { lock.withLock { starved } }
    /// Pulls that needed at least one invented sample.
    public var starvedPullCount: Int { lock.withLock { starvedPulls } }

    /// Appends as many samples as fit and returns how many were taken.
    public func tryPush(_ points: ArraySlice<LaserPoint>) -> Int {
        lock.withLock {
            let accepted = min(points.count, capacity - count)
            var tail = (head + count) % capacity
            for point in points.prefix(accepted) {
                storage[tail] = point
                tail = (tail + 1) % capacity
            }
            count += accepted
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

    /// Takes exactly `requested` samples, topping up with blanked samples at the
    /// last position when fewer are buffered. Never waits.
    public func pull(_ requested: Int) -> [LaserPoint] {
        guard requested > 0 else { return [] }
        return lock.withLock {
            let available = min(requested, count)
            var out: [LaserPoint] = []
            out.reserveCapacity(requested)
            for _ in 0..<available {
                out.append(storage[head])
                head = (head + 1) % capacity
            }
            count -= available
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

    /// Drops everything buffered, e.g. when the source is replaced.
    public func clear() {
        lock.withLock { head = 0; count = 0 }
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
