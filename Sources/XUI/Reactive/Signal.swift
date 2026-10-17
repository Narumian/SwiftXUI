import Foundation

/// A same-thread push channel: `send` invokes every live subscriber
/// synchronously, on the calling thread, before returning — no queueing, no
/// deferral to the next `lower`/`render` pass. This is the default case for
/// an event that already originates on the thread that owns the view tree
/// (e.g. a UI action fired from the same run loop turn). Those events get
/// genuine push with none of `BufferedSignal`'s locking.
///
/// Not internally synchronized — same contract as `StateStore`: touched only
/// from the single thread that owns it. A producer that can't guarantee that
/// thread must go through `BufferedSignal` instead of calling `send` here
/// directly. `@unchecked Sendable` asserts that contract (same as
/// `StateStore`) rather than enforcing it — needed so a value type can hold
/// one as a stored property (e.g. a `Sendable` model type) without
/// losing its own `Sendable` conformance.
public final class Signal<Value>: @unchecked Sendable {
    private struct Entry {
        let id: Int
        let handler: (Value) -> Void
    }

    private var entries: [Entry] = []
    private var nextID = 0

    public init() {}

    /// Send `value` to every current subscriber, in subscription order, on
    /// the calling thread. A handler that subscribes or cancels during this
    /// call only affects subsequent `send`s, not the one in progress —
    /// `entries` is a value-type snapshot for the duration of the loop.
    public func send(_ value: Value) {
        for entry in entries { entry.handler(value) }
    }

    /// Subscribe `handler`. It stays live until the returned `Subscription`
    /// is cancelled or deinitialized — the only way to unsubscribe, same as
    /// Combine's `AnyCancellable`.
    public func subscribe(_ handler: @escaping (Value) -> Void) -> Subscription {
        let id = nextID
        nextID += 1
        entries.append(Entry(id: id, handler: handler))
        return Subscription { [weak self] in
            self?.entries.removeAll { $0.id == id }
        }
    }
}

public extension Signal where Value == Void {
    func send() { send(()) }
}

/// A live subscription's cancellation token. Cancelling twice, or letting it
/// deinit after an explicit `cancel()`, is harmless.
public final class Subscription {
    private var onCancel: (() -> Void)?

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel?()
        onCancel = nil
    }

    deinit { cancel() }
}
