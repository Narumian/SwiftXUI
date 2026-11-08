import Foundation
@_exported import XCombine

/// A same-thread push channel: `send` invokes every live subscriber synchronously, on the
/// calling thread, before returning — no queueing, no deferral to the next `lower`/`render`
/// pass. This is the default case for an event that already originates on the thread that
/// owns the view tree (e.g. a UI action fired from the same run loop turn).
///
/// It is `XPassthroughSubject<Value, Never>`: the XCombine subject with Combine's grammar
/// (`sink`, `map`, `combineLatest`, `switchToLatest`, `store(in:)`, …). `subscribe` stays as
/// the short form of `sink(receiveValue:)`.
///
/// Not internally synchronized — same contract as `StateStore`: touched only from the single
/// thread that owns it. A producer that can't guarantee that thread must go through
/// `BufferedSignal` instead of calling `send` here directly.
public typealias Signal<Value> = XPassthroughSubject<Value, Never>

/// A live subscription's cancellation token. Cancelling twice, or letting it deinit after an
/// explicit `cancel()`, is harmless; deinit cancels.
public typealias Subscription = XAnyCancellable

public extension XPassthroughSubject where Failure == Never {
    /// Subscribe `handler`. It stays live until the returned `Subscription` is cancelled or
    /// deinitialized — the only way to unsubscribe, same as Combine's `AnyCancellable`.
    func subscribe(_ handler: @escaping (Output) -> Void) -> Subscription {
        sink(receiveValue: handler)
    }
}
