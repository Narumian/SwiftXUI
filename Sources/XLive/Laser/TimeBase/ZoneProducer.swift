import Foundation

/// Makes a zone's samples at the pace of the clock, not of anyone who reads them. Point `i` of the ring belongs to the
/// time `epoch + i / rate`, and the producer keeps the write cursor at `now + horizon`: a zone's time is the points
/// made divided by the rate, and it does not drift from the clock. Frames are of any length; a frame is written whole.
public actor ZoneProducer {
    public nonisolated let ring: ZoneRing
    public nonisolated let rate: UInt32
    public nonisolated let epoch: Double
    private final class HorizonBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double
        let longest: Double
        init(_ value: Double, longest: Double) { self.value = value; self.longest = max(value, longest) }
        var current: Double { lock.withLock { value } }
        func raise(to wanted: Double) { lock.withLock { value = max(value, min(wanted, longest)) } }
    }
    private nonisolated let horizonBox: HorizonBox
    /// How far ahead of the clock the write cursor is kept, in seconds.
    public nonisolated var horizon: Double { horizonBox.current }
    private let clock: any ZoneClock
    private let next: @Sendable () async throws -> [LaserPoint]?
    private var task: Task<Void, Never>?
    public private(set) var failure: String?
    public private(set) var finished = false

    /// What the producer did, for diagnostics.
    public struct Stats: Sendable, Equatable {
        public var frames = 0
        public var points = 0
        public var largestFrame = 0
        /// The longest a frame took to make, in seconds.
        public var slowestFrame = 0.0
        /// The most the write cursor was behind the clock when a round started, in seconds (0 when it never fell behind).
        public var worstLag = 0.0
    }
    public private(set) var stats = Stats()

    private final class Box<Iterator: AsyncIteratorProtocol>: @unchecked Sendable where Iterator.Element == [LaserPoint] {
        var iterator: Iterator
        init(_ iterator: Iterator) { self.iterator = iterator }
        func next() async throws -> [LaserPoint]? { try await iterator.next() }
    }

    /// - Parameters:
    ///   - horizon: how far ahead of the clock the write cursor is kept, in seconds. It has to cover what a device
    ///     keeps queued, since a device plays what it was given earlier.
    ///   - ringSeconds: how much the ring holds, in seconds of the zone.
    public init<Source: AsyncSequence & Sendable>(source: Source, rate: UInt32, clock: any ZoneClock,
                                                    horizon: Double = 0.25, ringSeconds: Double = 1) where Source.Element == [LaserPoint] {
        let rate = max(1, rate)
        self.rate = rate
        self.clock = clock
        self.epoch = clock.now
        horizonBox = HorizonBox(max(0.001, horizon), longest: ringSeconds / 2)
        ring = ZoneRing(capacity: max(1024, Int(Double(rate) * max(ringSeconds, horizon * 2))))
        let box = Box(source.makeAsyncIterator())
        next = { try await box.next() }
    }

    /// Writes frames until the write cursor reaches the time `time`. Returns how many points were written.
    @discardableResult
    public func produce(upTo time: Double) async -> Int {
        guard !finished else { return 0 }
        let target = Int((time - epoch) * Double(rate))
        var made = 0
        let behind = Double(clock.now - epoch) - Double(ring.writtenCount) / Double(rate)
        if behind > stats.worstLag { stats.worstLag = behind }
        while ring.writtenCount < target {
            if Task.isCancelled { break }
            do {
                let began = clock.now
                guard let points = try await next() else { finished = true; break }
                guard !points.isEmpty else { continue }
                let took = clock.now - began
                stats.frames += 1; stats.points += points.count
                stats.largestFrame = max(stats.largestFrame, points.count)
                stats.slowestFrame = max(stats.slowestFrame, took)
                ring.write(points, startsFrame: true)
                made += points.count
            } catch {
                failure = error.localizedDescription
                finished = true
                break
            }
        }
        return made
    }

    /// Makes the zone at least this far ahead from now on (a device that queues more needs more). Never shortens, and
    /// stays within half of what the ring holds.
    public nonisolated func require(horizon wanted: Double) {
        horizonBox.raise(to: wanted)
    }

    /// Runs on the clock until stopped: wakes often, and writes whatever the cursor is short of.
    public func start() {
        guard task == nil else { return }
        let wake = 0.01
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = self.clock.now
                await self.produce(upTo: now + self.horizon)
                if await self.isFinished { return }
                do { try await self.clock.sleep(until: now + wake) } catch { return }
            }
        }
    }

    private var isFinished: Bool { finished }

    public func stop() {
        task?.cancel(); task = nil
    }
}
