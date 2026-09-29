import Foundation

/// The `FX` counterpart to `XView`'s `_OnRemoveModifier` (`Reactive/OnRemove.swift`)
/// — same rationale: `value`/`action` refresh on every walk this effect is
/// still declared, and the first pass it's skipped, `action` runs once with
/// whatever was last declared.
public struct _FXOnRemoveModifier<Content: FX, Value>: FX, _PrimitiveFX {
    public typealias Body = Never
    let content: Content
    let value: Value
    let action: (Value) -> Void

    public func _emit(id: StateIdentity, store: StateStore, into out: inout [any FX]) {
        let box: StateStore.Box<Value> = store.box(for: id.child(type: Self.self)) { value }
        box.value = value
        box.onRemove = action
        emit(content, id: id, store: store, into: &out)
    }
}

public extension FX {
    /// Run `action` with `value`'s last-declared value the first time this
    /// effect stops being declared (e.g. via `stepContinuousFX`).
    func onRemove<Value>(_ value: Value, perform action: @escaping (Value) -> Void) -> _FXOnRemoveModifier<Self, Value> {
        _FXOnRemoveModifier(content: self, value: value, action: action)
    }

    /// `onRemove(_:perform:)` for when only the fact of disappearing matters,
    /// not any particular value.
    func onRemove(perform action: @escaping () -> Void) -> _FXOnRemoveModifier<Self, Void> {
        onRemove((), perform: { _ in action() })
    }
}
