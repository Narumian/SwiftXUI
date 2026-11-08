import Foundation
import Dispatch

/// A publisher that emits at a fixed interval, shaped like Combine's `Timer.publish(every:on:in:)`
/// with `autoconnect()`.
///
/// The timer runs only while someone is subscribed: the first subscription starts it, and
/// cancelling the last one stops it. Every subscriber shares the one underlying timer.
///
/// Each value is the time of that firing in seconds on a monotonic clock (system uptime by
/// default), so a subscriber that wants the step takes the difference from the previous value.
/// Values are delivered on `queue`, which is the owning thread of the graph — the main queue
/// unless you say otherwise. Subscribe and cancel from that same queue; the subscriber list is
/// locked only so that a mistake does not corrupt it.
///
///     let clock = XTimer(every: 1.0 / 60)
///     let token = clock.sink { time in … }      // starts firing
///     token.cancel()                            // and stops
///
/// A late firing is not made up: if the queue is busy, firings are skipped, not queued.
public final class XTimer: XPublisher, @unchecked Sendable {
    public typealias Output = Double
    public typealias Failure = Never

    public let interval: Double
    public let queue: DispatchQueue
    private let leeway: DispatchTimeInterval
    private let now: @Sendable () -> Double

    private let lock = _XLock()
    private var links: [_TimerLink] = []
    private var source: DispatchSourceTimer?

    /// - Parameters:
    ///   - interval: Seconds between firings. Non-finite or below one microsecond is raised to that.
    ///   - queue: The queue values are delivered on.
    ///   - leeway: How late the system may fire, to save power.
    ///   - now: The clock behind the values; replace it in tests.
    public init(every interval: Double, queue: DispatchQueue = .main, leeway: DispatchTimeInterval = .milliseconds(1),
                now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.interval = interval.isFinite ? max(1e-6, interval) : 1
        self.queue = queue
        self.leeway = leeway
        self.now = now
    }

    /// The spelling Combine users know.
    public static func publish(every interval: Double, queue: DispatchQueue = .main) -> XTimer {
        XTimer(every: interval, queue: queue)
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return source != nil }

    public func receive<S: XSubscriber>(subscriber: S) where S.Input == Double, S.Failure == Never {
        let link = _TimerLink(owner: self) { subscriber.receive($0) }
        lock.lock()
        links.append(link)
        if source == nil { startLocked() }
        lock.unlock()
        subscriber.receive(subscription: link)
    }

    fileprivate func remove(_ link: _TimerLink) {
        lock.lock()
        links.removeAll { $0 === link }
        let stopped = links.isEmpty ? takeSourceLocked() : nil
        lock.unlock()
        stopped?.cancel()
    }

    private func takeSourceLocked() -> DispatchSourceTimer? {
        let s = source; source = nil; return s
    }

    private func startLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        timer.setEventHandler { [weak self] in self?.fire() }
        source = timer
        timer.resume()
    }

    private func fire() {
        let time = now()
        lock.lock()
        let snapshot = links
        lock.unlock()
        for link in snapshot where link.isActive { link.deliver(time) }
    }
}

/// One subscriber's end of an `XTimer`. Cancelling it removes it and, if it was the last, stops the timer.
private final class _TimerLink: XSubscription, @unchecked Sendable {
    private let lock = _XLock()
    private var owner: XTimer?
    private var sink: ((Double) -> Void)?

    init(owner: XTimer, sink: @escaping (Double) -> Void) {
        self.owner = owner; self.sink = sink
    }

    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return sink != nil }

    func deliver(_ time: Double) {
        lock.lock(); let sink = self.sink; lock.unlock()
        sink?(time)
    }

    func cancel() {
        lock.lock()
        let owner = self.owner
        self.owner = nil; sink = nil
        lock.unlock()
        owner?.remove(self)
    }
}
