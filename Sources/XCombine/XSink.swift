public extension XSubscribers {
    /// Terminal subscriber that runs closures. Cancelling it cancels the upstream link.
    final class Sink<Input, Failure: Error>: XSubscriber, XCancellable {
        @usableFromInline @exclusivity(unchecked) var subscription: (any XSubscription)?
        @usableFromInline @exclusivity(unchecked) var isDone = false
        @usableFromInline let receiveValue: (Input) -> Void
        @usableFromInline let receiveCompletion: (XSubscribers.Completion<Failure>) -> Void

        @inlinable public init(receiveCompletion: @escaping (XSubscribers.Completion<Failure>) -> Void,
                               receiveValue: @escaping (Input) -> Void) {
            self.receiveCompletion = receiveCompletion
            self.receiveValue = receiveValue
        }

        @inlinable public func receive(subscription: any XSubscription) {
            if isDone { subscription.cancel(); return }
            self.subscription = subscription
        }

        @inlinable public func receive(_ input: Input) {
            guard !isDone else { return }
            receiveValue(input)
        }

        @inlinable public func receive(completion: XSubscribers.Completion<Failure>) {
            guard !isDone else { return }
            isDone = true
            subscription = nil
            receiveCompletion(completion)
        }

        @inlinable public func cancel() {
            isDone = true
            let s = subscription
            subscription = nil
            s?.cancel()
        }
    }
}

public extension XPublisher {
    /// Subscribes with closures and returns the token that keeps the subscription alive.
    @inlinable func sink(receiveCompletion: @escaping (XSubscribers.Completion<Failure>) -> Void,
                         receiveValue: @escaping (Output) -> Void) -> XAnyCancellable {
        let sink = XSubscribers.Sink<Output, Failure>(receiveCompletion: receiveCompletion, receiveValue: receiveValue)
        receive(subscriber: sink)
        return XAnyCancellable(sink)
    }
}

public extension XPublisher where Failure == Never {
    @inlinable func sink(receiveValue: @escaping (Output) -> Void) -> XAnyCancellable {
        sink(receiveCompletion: { _ in }, receiveValue: receiveValue)
    }
}
