/// A source of values over time, shaped like Combine's `Publisher`.
///
/// Differences from Combine, on purpose:
/// - There is no demand: every subscriber is unlimited, so `XSubscription` is just cancellation.
/// - Nothing is synchronized. A graph is touched only from the thread/actor that owns it; a
///   producer on another thread hops over first (see `XPublisher.values`).
public protocol XPublisher<Output, Failure> {
    associatedtype Output
    associatedtype Failure: Error
    func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure
}

/// The link a subscriber holds back to its source. Cancelling it stops delivery at once —
/// including a value already being fanned out when `cancel()` is called.
public protocol XSubscription: AnyObject, XCancellable {}

public protocol XSubscriber {
    associatedtype Input
    associatedtype Failure: Error
    func receive(subscription: any XSubscription)
    func receive(_ input: Input)
    func receive(completion: XSubscribers.Completion<Failure>)
}

public enum XSubscribers {
    public enum Completion<Failure: Error> {
        case finished
        case failure(Failure)
    }
}

extension XSubscribers.Completion: Sendable where Failure: Sendable {}

public enum XPublishers {}

/// Hands out the same inert subscription to publishers that finish immediately.
@usableFromInline final class _InertSubscription: XSubscription, @unchecked Sendable {
    @usableFromInline static let shared = _InertSubscription()
    @inlinable func cancel() {}
}
