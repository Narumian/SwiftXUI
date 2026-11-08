/// A publisher you can push values into by hand.
public protocol XSubject<Output, Failure>: AnyObject, XPublisher {
    func send(_ value: Output)
    func send(completion: XSubscribers.Completion<Failure>)
}

// MARK: - Shared fan-out machinery

/// One live subscriber of a subject. The subject keeps these in subscription order; a
/// conduit flips `isActive` the moment it is cancelled, so a value already being fanned out
/// never reaches a subscriber that cancelled partway through.
///
/// The conduit is deliberately not generic over the subscriber: delivery goes through
/// closures built at subscription time. A virtual call into a generic subclass would run
/// unspecialized (metadata lookups and witness thunks on every value); a closure formed in
/// the caller's module is specialized for the concrete downstream and the chain behind it.
@usableFromInline enum _ConduitEvent<Output, Failure: Error> {
    case value(Output)
    case completion(XSubscribers.Completion<Failure>)
}

@usableFromInline final class _Conduit<Output, Failure: Error>: XSubscription {
    @usableFromInline @exclusivity(unchecked) var isActive = true
    @usableFromInline @exclusivity(unchecked) var deliver: (_ConduitEvent<Output, Failure>) -> Void
    /// Strong on purpose: a `weak` back-reference costs a side-table allocation per subject
    /// and a load per cancel. It adds no leak that was not there already — the downstream
    /// holds this conduit, this holds the downstream, and `cancel()` is what breaks that.
    @usableFromInline @exclusivity(unchecked) var owner: _SubjectCore<Output, Failure>?

    @inlinable init(owner: _SubjectCore<Output, Failure>,
                    deliver: @escaping (_ConduitEvent<Output, Failure>) -> Void) {
        self.owner = owner
        self.deliver = deliver
    }

    @inlinable func offer(_ value: Output) { deliver(.value(value)) }

    @inlinable func finish(_ completion: XSubscribers.Completion<Failure>) {
        guard isActive else { return }
        isActive = false
        let handler = deliver
        deliver = { _ in }
        owner = nil
        handler(.completion(completion))
    }

    @inlinable func cancel() {
        guard isActive else { return }
        isActive = false
        deliver = { _ in }
        let o = owner
        owner = nil
        o?.remove(self)
    }
}

/// Subscriber list and delivery shared by both subjects.
@usableFromInline final class _SubjectCore<Output, Failure: Error> {
    @usableFromInline @exclusivity(unchecked) var conduits: [_Conduit<Output, Failure>] = []
    @usableFromInline @exclusivity(unchecked) var completion: XSubscribers.Completion<Failure>?

    @inlinable init() {}

    @inlinable func remove(_ conduit: _Conduit<Output, Failure>) {
        if let index = conduits.firstIndex(where: { $0 === conduit }) { conduits.remove(at: index) }
    }

    @inlinable func deliver(_ value: Output) {
        guard completion == nil else { return }
        // Iterate a snapshot: a handler may subscribe or cancel mid-fan-out. A cancelled
        // conduit is skipped via `isActive`; a new one only sees later values.
        for conduit in conduits where conduit.isActive { conduit.offer(value) }
    }

    @inlinable func complete(_ completion: XSubscribers.Completion<Failure>) {
        guard self.completion == nil else { return }
        self.completion = completion
        let all = conduits
        conduits.removeAll()
        for conduit in all { conduit.finish(completion) }
    }

    @inlinable func attach<S: XSubscriber>(_ subscriber: S) -> _Conduit<Output, Failure>?
    where S.Input == Output, S.Failure == Failure {
        if let completion {
            subscriber.receive(subscription: _InertSubscription.shared)
            subscriber.receive(completion: completion)
            return nil
        }
        let conduit = _Conduit<Output, Failure>(owner: self) { event in
            switch event {
            case .value(let value): subscriber.receive(value)
            case .completion(let completion): subscriber.receive(completion: completion)
            }
        }
        conduits.append(conduit)
        subscriber.receive(subscription: conduit)
        return conduit
    }
}

// MARK: - XPassthroughSubject

/// Broadcasts each value to the current subscribers; keeps no value of its own.
public final class XPassthroughSubject<Output, Failure: Error>: XSubject, @unchecked Sendable {
    @usableFromInline let core = _SubjectCore<Output, Failure>()

    public init() {}

    @inlinable public func send(_ value: Output) { core.deliver(value) }
    @inlinable public func send(completion: XSubscribers.Completion<Failure>) { core.complete(completion) }

    @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
        _ = core.attach(subscriber)
    }
}

public extension XPassthroughSubject where Output == Void {
    @inlinable func send() { send(()) }
}

// MARK: - XCurrentValueSubject

/// Holds a current value and replays it to each new subscriber before later values.
public final class XCurrentValueSubject<Output, Failure: Error>: XSubject, @unchecked Sendable {
    @usableFromInline let core = _SubjectCore<Output, Failure>()
    @usableFromInline @exclusivity(unchecked) var current: Output

    public init(_ value: Output) { current = value }

    /// Reading returns the latest value; writing sends it.
    @inlinable public var value: Output {
        get { current }
        set { send(newValue) }
    }

    @inlinable public func send(_ value: Output) {
        guard core.completion == nil else { return }
        current = value
        core.deliver(value)
    }

    @inlinable public func send(completion: XSubscribers.Completion<Failure>) { core.complete(completion) }

    @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
        if let conduit = core.attach(subscriber), conduit.isActive {
            conduit.offer(current)
        }
    }
}

public extension XCurrentValueSubject where Output == Void {
    @inlinable func send() { send(()) }
}
