import Foundation

/// Keeps `value`'s latest declaration on a `Box`, and — the first time this
/// node's identity goes an entire pass without being redeclared — hands that
/// last value to `action`, once. The identity-keyed counterpart to SwiftUI's
/// `.onDisappear`.
///
/// Unlike `.onReceive`'s one-time subscription, `value`/`action` are
/// refreshed on *every* walk this node is still declared, not installed once
/// — what should run on removal is whatever was true the last time it was
/// declared, not whatever was true the first time. Overwriting a `Box`'s
/// single `onRemove` slot every walk is harmless (unlike re-subscribing to a
/// `Signal`, which would pile up duplicate handlers).
public struct _OnRemoveModifier<Content: XView, Value>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let value: Value
    let action: (Value) -> Void

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let box: StateStore.Box<Value> = store.box(for: id.child(type: Self.self)) { value }
        box.value = value
        box.onRemove = action
        return await lower(content, id: id, store: store)
    }
}

public extension XView {
    /// Run `action` with `value`'s last-declared value the first time this
    /// node stops being declared.
    func onRemove<Value>(_ value: Value, perform action: @escaping (Value) -> Void) -> _OnRemoveModifier<Self, Value> {
        _OnRemoveModifier(content: self, value: value, action: action)
    }

    /// `onRemove(_:perform:)` for when only the fact of disappearing matters,
    /// not any particular value.
    func onRemove(perform action: @escaping () -> Void) -> _OnRemoveModifier<Self, Void> {
        onRemove((), perform: { _ in action() })
    }
}
