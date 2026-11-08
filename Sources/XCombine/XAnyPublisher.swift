// MARK: - Type erasure

@usableFromInline class _AnySubscriberBox<Input, Failure: Error> {
    @inlinable init() {}
    @inlinable func receive(subscription: any XSubscription) { fatalError("abstract") }
    @inlinable func receive(_ input: Input) { fatalError("abstract") }
    @inlinable func receive(completion: XSubscribers.Completion<Failure>) { fatalError("abstract") }
}

@usableFromInline final class _ConcreteSubscriberBox<S: XSubscriber>: _AnySubscriberBox<S.Input, S.Failure> {
    @usableFromInline let base: S
    @inlinable init(_ base: S) { self.base = base }
    @inlinable override func receive(subscription: any XSubscription) { base.receive(subscription: subscription) }
    @inlinable override func receive(_ input: S.Input) { base.receive(input) }
    @inlinable override func receive(completion: XSubscribers.Completion<S.Failure>) { base.receive(completion: completion) }
}

public struct XAnySubscriber<Input, Failure: Error>: XSubscriber {
    @usableFromInline let box: _AnySubscriberBox<Input, Failure>

    @inlinable public init<S: XSubscriber>(_ subscriber: S) where S.Input == Input, S.Failure == Failure {
        box = _ConcreteSubscriberBox(subscriber)
    }
    @inlinable public func receive(subscription: any XSubscription) { box.receive(subscription: subscription) }
    @inlinable public func receive(_ input: Input) { box.receive(input) }
    @inlinable public func receive(completion: XSubscribers.Completion<Failure>) { box.receive(completion: completion) }
}

/// A publisher with its concrete type hidden. Costs one extra hop per subscription.
public struct XAnyPublisher<Output, Failure: Error>: XPublisher {
    @usableFromInline let subscribe: (XAnySubscriber<Output, Failure>) -> Void

    @inlinable public init<P: XPublisher>(_ publisher: P) where P.Output == Output, P.Failure == Failure {
        subscribe = { publisher.receive(subscriber: $0) }
    }

    @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
        subscribe(XAnySubscriber(subscriber))
    }
}

public extension XPublisher {
    @inlinable func eraseToAnyPublisher() -> XAnyPublisher<Output, Failure> { XAnyPublisher(self) }
}

// MARK: - Just / Empty / Fail

public extension XPublishers {
    /// Emits one value, then finishes.
    struct Just<Output>: XPublisher {
        public typealias Failure = Never
        public let output: Output
        @inlinable public init(_ output: Output) { self.output = output }
        @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Never {
            subscriber.receive(subscription: _InertSubscription.shared)
            subscriber.receive(output)
            subscriber.receive(completion: .finished)
        }
    }

    /// Finishes at once without a value (or never finishes, when `completeImmediately` is false).
    struct Empty<Output, Failure: Error>: XPublisher {
        public let completeImmediately: Bool
        @inlinable public init(completeImmediately: Bool = true) { self.completeImmediately = completeImmediately }
        @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            subscriber.receive(subscription: _InertSubscription.shared)
            if completeImmediately { subscriber.receive(completion: .finished) }
        }
    }

    struct Fail<Output, Failure: Error>: XPublisher {
        public let error: Failure
        @inlinable public init(error: Failure) { self.error = error }
        @inlinable public func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            subscriber.receive(subscription: _InertSubscription.shared)
            subscriber.receive(completion: .failure(error))
        }
    }
}

public typealias XJust<Output> = XPublishers.Just<Output>
public typealias XEmpty<Output, Failure: Error> = XPublishers.Empty<Output, Failure>
public typealias XFail<Output, Failure: Error> = XPublishers.Fail<Output, Failure>
