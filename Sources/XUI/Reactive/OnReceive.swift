import Foundation

/// Subscribes `action` to `signal` the first time this node is walked, and
/// keeps that one subscription alive across later walks by keying it to this
/// node's `StateIdentity` — the same identity-keyed persistence `@XState`
/// uses, so a view declared fresh every frame still subscribes exactly once.
/// When the node stops being declared, `StateStore.endPass()` drops its box,
/// the held `Subscription` deinitializes, and `Signal` un-subscribes it —
/// no explicit teardown code needed.
public struct _OnReceiveModifier<Content: XView, Value>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let signal: Signal<Value>
    let action: (Value) -> Void

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let box: StateStore.Box<Subscription?> = store.box(for: id.child(type: Self.self)) { nil }
        if box.value == nil {
            box.value = signal.subscribe(action)
        }
        return lower(content, id: id, store: store)
    }
}

public extension XView {
    /// React to `signal` for as long as this node stays in the declared
    /// tree. `action` runs synchronously, on whatever thread called
    /// `signal.send` — for a `Signal` fed only from the render thread, that's
    /// during the same walk or between walks, never mid-layout.
    func onReceive<Value>(_ signal: Signal<Value>, perform action: @escaping (Value) -> Void) -> _OnReceiveModifier<Self, Value> {
        _OnReceiveModifier(content: self, signal: signal, action: action)
    }
}
