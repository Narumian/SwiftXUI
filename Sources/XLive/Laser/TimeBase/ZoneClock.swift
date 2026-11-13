import Foundation

/// The zone's time base: seconds on a monotonic clock, and a way to wait until a time. The producer and every output
/// read the same clock, so they agree on what "now" is however differently the devices run. Tests move it by hand.
public protocol ZoneClock: Sendable {
    var now: Double { get }
    /// Returns when `now >= time`, or throws if the task is cancelled first.
    func sleep(until time: Double) async throws
}

/// The host's monotonic clock.
public struct HostZoneClock: ZoneClock {
    public init() {}
    public var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    public func sleep(until time: Double) async throws {
        let wait = time - now
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) } else { try Task.checkCancellation() }
    }
}

/// A clock that moves only when told to, for tests. `advance` wakes the sleepers whose time has come.
public final class ManualZoneClock: ZoneClock, @unchecked Sendable {
    private struct Sleeper { let id: UUID; let time: Double; let continuation: CheckedContinuation<Void, any Error> }
    private let lock = NSLock()
    private var time: Double
    private var sleepers: [Sleeper] = []

    public init(start: Double = 0) { time = start }

    public var now: Double { lock.withLock { time } }

    public func advance(to newTime: Double) {
        let due: [Sleeper] = lock.withLock {
            time = max(time, newTime)
            let due = sleepers.filter { $0.time <= time }.sorted { $0.time < $1.time }
            sleepers.removeAll { $0.time <= time }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    public func advance(by seconds: Double) { advance(to: now + seconds) }

    public func sleep(until wake: Double) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock(); continuation.resume(throwing: CancellationError())
                } else if wake <= time {
                    lock.unlock(); continuation.resume()
                } else {
                    sleepers.append(Sleeper(id: id, time: wake, continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            self.lock.lock()
            let sleeper = self.sleepers.firstIndex { $0.id == id }.map { self.sleepers.remove(at: $0) }
            self.lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// The number of tasks waiting on the clock.
    public var sleeperCount: Int { lock.withLock { sleepers.count } }
}
