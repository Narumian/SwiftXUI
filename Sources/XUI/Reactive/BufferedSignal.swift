import Foundation

/// The cross-thread safety valve for `Signal`: a producer that can't
/// guarantee it runs on the tree's owning thread calls `send` here instead,
/// from any thread. `drain(into:)` flushes everything queued since the last
/// drain onto a same-thread `Signal`, in arrival order, when called from the
/// thread that owns it — typically once per frame, from the owning system's
/// own per-frame step (mirrors `BattleFX.step(ft:)` stepping its other
/// continuous fields).
///
/// This is the exception path, not the default — an event that already
/// originates on the render thread should use `Signal` directly and skip the
/// locking entirely.
public final class BufferedSignal<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Value] = []

    public init() {}

    /// Safe to call from any thread.
    public func send(_ value: Value) {
        lock.lock()
        pending.append(value)
        lock.unlock()
    }

    /// Flush everything queued since the last drain into `signal`, in order,
    /// on the calling thread.
    public func drain(into signal: Signal<Value>) {
        drain { signal.send($0) }
    }

    /// Flush everything queued since the last drain to `consume`, in order,
    /// on the calling thread — for a producer that hands off to something
    /// other than a same-shaped `Signal`, e.g. spawning a `Task` per drained
    /// value to call into an actor.
    public func drain(_ consume: (Value) -> Void) {
        lock.lock()
        let values = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        for value in values { consume(value) }
    }
}
