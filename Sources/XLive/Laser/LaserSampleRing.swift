import Foundation

public final class LaserSampleRing: @unchecked Sendable {
    public let capacity: Int
    public let maximumReaderLagSamples: Int
    private let lock = NSLock()
    private var storage: [LaserPoint]
    private let startedAt = DispatchTime.now().uptimeNanoseconds

    private var written = 0
    private struct AvailabilityWaiter {
        let id: UUID
        let threshold: Int
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct SpaceWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var availabilityWaiters: [AvailabilityWaiter] = []
    private var spaceWaiters: [SpaceWaiter] = []
    private struct ReadWaiter {
        let id: UUID
        let reader: Reader
        let requested: Int
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var readWaiters: [ReadWaiter] = []

    private var readers: [ObjectIdentifier: WeakReader] = [:]
    private struct WeakReader { weak var reader: Reader? }
    private var live: [Reader] {
        readers = readers.filter { $0.value.reader != nil }
        return readers.values.compactMap(\.reader)
    }

    public init(capacity: Int, maximumReaderLagSamples: Int? = nil) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.maximumReaderLagSamples = min(capacity, max(1, maximumReaderLagSamples ?? capacity))
        storage = Array(repeating: try! LaserPoint(xy: .zero, rgb: .zero, isBlanked: true), count: capacity)
    }

    public var availableLength: Int { lock.withLock { availableLengthLocked() } }

    public func waitForAvailableLength(atMost threshold: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if !live.isEmpty && availableLengthLocked() <= max(0, threshold) {
                    lock.unlock()
                    continuation.resume()
                } else {
                    availabilityWaiters.append(AvailabilityWaiter(id: id, threshold: max(0, threshold), continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            self.lock.lock()
            let waiter = self.availabilityWaiters.firstIndex { $0.id == id }.map { self.availabilityWaiters.remove(at: $0) }
            self.lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    private func waitForSpace() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if hasSpaceLocked() {
                    lock.unlock()
                    continuation.resume()
                } else {
                    spaceWaiters.append(SpaceWaiter(id: id, continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            self.lock.lock()
            let waiter = self.spaceWaiters.firstIndex { $0.id == id }.map { self.spaceWaiters.remove(at: $0) }
            self.lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    public final class Reader: @unchecked Sendable {
        fileprivate let ring: LaserSampleRing
        fileprivate var maximumLagSamples: Int
        fileprivate var position: Int
        fileprivate var starved = 0
        fileprivate var starvedPulls = 0
        fileprivate var skipped = 0
        fileprivate var recentStarvations: [String] = []
        fileprivate init(ring: LaserSampleRing, position: Int, maximumLagSamples: Int) {
            self.ring = ring; self.position = position; self.maximumLagSamples = maximumLagSamples
        }

        public var fill: Int { ring.lock.withLock { min(ring.capacity, ring.written - position) } }

        /// Lets this reader lag at least this far behind the writer before it skips ahead (never less than it had). The
        /// limit exists to drop what is old, and what the writer pushes in one piece (a long frame) is not old.
        public func allowLag(atLeast samples: Int) {
            ring.lock.withLock { maximumLagSamples = max(maximumLagSamples, min(ring.capacity, samples)) }
        }

        public var starvedSamples: Int { ring.lock.withLock { starved } }

        public var starvedPullCount: Int { ring.lock.withLock { starvedPulls } }

        public var skippedSamples: Int { ring.lock.withLock { skipped } }
        public var starvationTrace: String { ring.lock.withLock { recentStarvations.joined(separator: ",") } }

        @discardableResult
        public func catchUpIfNeeded() -> Int {
            ring.lock.withLock {
                let before = skipped
                ring.catchUp(self, maximumLag: maximumLagSamples)
                ring.resumeAvailabilityWaitersIfReady()
                return skipped - before
            }
        }

        public func waitForAvailableLength(atLeast requested: Int) async throws {
            guard requested > 0 else { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    ring.lock.lock()
                    if Task.isCancelled {
                        ring.lock.unlock()
                        continuation.resume(throwing: CancellationError())
                    } else if ring.availableLengthLocked(for: self, maximumLag: maximumLagSamples) >= requested {
                        ring.lock.unlock()
                        continuation.resume()
                    } else {
                        ring.readWaiters.append(ReadWaiter(id: id, reader: self, requested: requested, continuation: continuation))
                        ring.lock.unlock()
                    }
                }
            } onCancel: {
                self.ring.lock.lock()
                let waiter = self.ring.readWaiters.firstIndex { $0.id == id }.map { self.ring.readWaiters.remove(at: $0) }
                self.ring.lock.unlock()
                waiter?.continuation.resume(throwing: CancellationError())
            }
        }

        public func pull(_ requested: Int) -> [LaserPoint] {
            guard requested > 0 else { return [] }
            return ring.lock.withLock {
                ring.catchUp(self, maximumLag: maximumLagSamples)
                let available = min(requested, ring.written - position)
                var out: [LaserPoint] = []
                out.reserveCapacity(available)
                for _ in 0..<available {
                    out.append(ring.storage[position % ring.capacity])
                    position += 1
                }
                if available < requested {
                    let missing = requested - available
                    starved += missing
                    starvedPulls += 1
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- ring.startedAt) / 1_000_000
                    recentStarvations.append(String(format: "%.1fms:-%d", elapsed, missing))
                    if recentStarvations.count > 16 { recentStarvations.removeFirst() }
                }
                ring.resumeAvailabilityWaitersIfReady()
                return out
            }
        }
    }

    public func makeReader(maximumLagSamples: Int? = nil) -> Reader {
        lock.withLock {
            let maximumLag = min(capacity, max(1, maximumLagSamples ?? maximumReaderLagSamples))
            let reader = Reader(ring: self, position: written, maximumLagSamples: maximumLag)
            readers[ObjectIdentifier(reader)] = WeakReader(reader: reader)
            resumeAvailabilityWaitersIfReady()
            return reader
        }
    }

    public func remove(_ reader: Reader) {
        lock.withLock {
            _ = readers.removeValue(forKey: ObjectIdentifier(reader))
            resumeAvailabilityWaitersIfReady()
        }
    }

    public var readerCount: Int { lock.withLock { live.count } }

    private func catchUp(_ reader: Reader, maximumLag: Int) {
        let oldest = max(written - capacity, written - maximumLag)
        if reader.position < oldest { reader.skipped += oldest - reader.position; reader.position = oldest }
    }

    private func availableLengthLocked(for reader: Reader, maximumLag: Int) -> Int {
        catchUp(reader, maximumLag: maximumLag)
        resumeAvailabilityWaitersIfReady()
        return max(0, written - reader.position)
    }

    private func resumeReadWaitersIfReady() {
        var ready: [CheckedContinuation<Void, any Error>] = []
        for index in readWaiters.indices.reversed() {
            let waiter = readWaiters[index]
            if availableLengthLocked(for: waiter.reader, maximumLag: waiter.reader.maximumLagSamples) >= waiter.requested {
                ready.append(readWaiters.remove(at: index).continuation)
            }
        }
        for continuation in ready { continuation.resume() }
    }

    public func tryPush(_ points: ArraySlice<LaserPoint>) -> Int {
        lock.withLock {
            guard let ahead = live.map(\.position).max() else { return 0 }
            let accepted = min(points.count, capacity - (written - max(ahead, written - capacity)))
            for point in points.prefix(accepted) {
                storage[written % capacity] = point
                written += 1
            }
            resumeReadWaitersIfReady()
            return accepted
        }
    }

    public func push(_ points: [LaserPoint]) async throws {
        var rest = points[...]
        while !rest.isEmpty {
            try Task.checkCancellation()
            let taken = tryPush(rest)
            rest = rest.dropFirst(taken)
            if !rest.isEmpty { try await waitForSpace() }
        }
    }

    public func clear() {
        lock.withLock {
            for reader in live { reader.position = written }
            resumeAvailabilityWaitersIfReady()
        }
    }

    private func availableLengthLocked() -> Int {
        guard let ahead = live.map(\.position).max() else { return 0 }
        return max(0, written - ahead)
    }

    private func hasSpaceLocked() -> Bool {
        guard let ahead = live.map(\.position).max() else { return false }
        let oldest = max(ahead, written - capacity)
        return written - oldest < capacity
    }

    private func resumeAvailabilityWaitersIfReady() {
        guard !live.isEmpty else { return }
        if !availabilityWaiters.isEmpty {
            let available = availableLengthLocked()
            let ready = availabilityWaiters.filter { available <= $0.threshold }
            availabilityWaiters.removeAll { available <= $0.threshold }
            for waiter in ready { waiter.continuation.resume() }
        }
        guard hasSpaceLocked(), !spaceWaiters.isEmpty else { return }
        let space = spaceWaiters
        spaceWaiters.removeAll()
        for waiter in space { waiter.continuation.resume() }
    }
}

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

    public mutating func reset() {
        current = nil
        following = nil
        phase = 0
        pending = []
        pendingIndex = 0
    }

    public mutating func convert(count: Int, chunk: Int = 64, pull: (Int) -> [LaserPoint]) -> [LaserPoint] {
        guard count > 0 else { return [] }
        if isPassthrough { return pull(count) }
        let step = sourceRate / outputRate
        var out: [LaserPoint] = []
        out.reserveCapacity(count)
        func next() -> LaserPoint {
            if pendingIndex == pending.count {

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

    public mutating func convertAsync(count: Int, chunk: Int = 16,
                                      pull: (Int) async throws -> [LaserPoint]) async throws -> [LaserPoint] {
        guard count > 0 else { return [] }
        if isPassthrough { return try await pull(count) }
        let step = sourceRate / outputRate
        var out: [LaserPoint] = []
        out.reserveCapacity(count)
        if current == nil { current = try await nextAsync(chunk: chunk, pull: pull); following = try await nextAsync(chunk: chunk, pull: pull) }
        for _ in 0..<count {
            out.append(Self.lerp(current!, following!, Float(phase)))
            phase += step
            while phase >= 1 {
                current = following
                following = try await nextAsync(chunk: chunk, pull: pull)
                phase -= 1
            }
        }
        return out
    }

    private mutating func nextAsync(chunk: Int, pull: (Int) async throws -> [LaserPoint]) async throws -> LaserPoint {
        if pendingIndex == pending.count {
            pending = try await pull(chunk)
            pendingIndex = 0
        }
        defer { pendingIndex += 1 }
        return pending[pendingIndex]
    }

    private static func lerp(_ a: LaserPoint, _ b: LaserPoint, _ t: Float) -> LaserPoint {
        if t == 0 { return a }
        func mix(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        let xy = SIMD2<Float>(min(1, max(-1, mix(a.xy.x, b.xy.x))), min(1, max(-1, mix(a.xy.y, b.xy.y))))
        let rgb = SIMD3<Float>(min(1, max(0, mix(a.rgb.x, b.rgb.x))), min(1, max(0, mix(a.rgb.y, b.rgb.y))), min(1, max(0, mix(a.rgb.z, b.rgb.z))))

        return try! LaserPoint(xy: xy, rgb: rgb, mode: a.isBlanked || b.isBlanked ? .blank : .normal)
    }
}
