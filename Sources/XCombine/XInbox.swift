/// The one place a value crosses from a foreign thread into an XCombine graph.
///
/// XCombine graphs are thread-confined: only their owning thread (or actor) subscribes,
/// sends and cancels. A producer that runs somewhere else — a CoreMIDI callback, an audio
/// render thread, a CoreMotion queue — calls `send` here instead, from any thread. The owner
/// calls `drain()` when it is ready (once per frame, or when `onWake` says something arrived),
/// and the queued values come out in arrival order as ordinary `XPassthroughSubject` output,
/// on the draining thread. Subscribers see an ordinary publisher, any number of them:
///
///     let inbox = XInbox<MIDIInputEvent>(overflow: .dropOldest(capacity: 4096))
///     let tokens = [inbox.sink { … }, inbox.filter { … }.sink { … }]   // owner thread
///     // CoreMIDI thread:  inbox.send(event)
///     // owner, per frame: inbox.drain()
///
/// Subscribing and cancelling go through the publisher side and so belong to the owner
/// thread, like any other XCombine subscription.
///
/// `send` takes a short lock and appends — no allocation once the buffers have grown, and no
/// subscriber code ever runs under the lock or on the producer's thread. `drain` swaps the
/// whole queue out under the lock and delivers outside it.
public final class XInbox<Output>: XPublisher, @unchecked Sendable {
    public typealias Failure = Never

    public enum Overflow: Sendable, Equatable {
        case unbounded
        /// Keep the newest `capacity` undrained values; the oldest are dropped and counted.
        case dropOldest(capacity: Int)
    }

    @usableFromInline let lock = _XLock()
    @usableFromInline var pending: [Output] = []
    /// Index of the first live element of `pending` (drops advance it instead of shifting).
    @usableFromInline var head = 0
    @usableFromInline var spare: [Output] = []
    @usableFromInline var dropped = 0
    @usableFromInline var wake: (@Sendable () -> Void)?
    @usableFromInline let capacity: Int?
    /// Owner thread only: stops a subscriber that calls `drain()` from recursing.
    @usableFromInline var isDraining = false
    @usableFromInline let output = XPassthroughSubject<Output, Never>()

    public init(overflow: Overflow = .unbounded) {
        switch overflow {
        case .unbounded: capacity = nil
        case .dropOldest(let capacity): self.capacity = max(1, capacity)
        }
    }

    // MARK: Producer side (any thread)

    /// Queue `value` for the owner. Safe from any thread, including a real-time-ish callback.
    @inlinable public func send(_ value: Output) where Output: Sendable {
        lock.lock()
        let wasEmpty = pending.count == head
        if let capacity, pending.count - head >= capacity {
            head += 1
            dropped += 1
            if head >= Swift.max(capacity, 64) {
                pending.removeFirst(head)
                head = 0
            }
        }
        pending.append(value)
        let notify = wasEmpty ? wake : nil
        lock.unlock()
        notify?()
    }

    /// Called, outside the lock and on the producer's thread, when a value arrives while the
    /// queue is empty — once per burst, not once per value. Use it to schedule `drain()` on
    /// the owner (for example a hop onto the actor that owns the graph). Pass `nil` to clear.
    public func onWake(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        wake = handler
        lock.unlock()
    }

    /// Values discarded by `.dropOldest` since creation. Any thread.
    public var droppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    /// Values queued and not yet drained. Any thread.
    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count - head
    }

    // MARK: Owner side

    /// Deliver everything queued so far, in arrival order, to the subscribers. Owner thread
    /// only. A value that a subscriber sends back into this inbox waits for the next drain
    /// (and re-fires `onWake`). Returns how many values were delivered.
    @discardableResult
    @inlinable public func drain() -> Int {
        guard !isDraining else { return 0 }
        isDraining = true
        defer { isDraining = false }
        lock.lock()
        swap(&pending, &spare)
        let start = head
        head = 0
        lock.unlock()
        let end = spare.count
        var index = start
        while index < end {
            output.send(spare[index])
            index += 1
        }
        spare.removeAll(keepingCapacity: true)
        return end - start
    }

    @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Never {
        output.receive(subscriber: subscriber)
    }
}
