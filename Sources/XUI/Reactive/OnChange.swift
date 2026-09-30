import Foundation

/// Diffs `value` against what this node last declared, and calls `action`
/// with `(old, new)` whenever it differs — `old` is `nil` on the first
/// declaration. Same identity-keyed persistence as `.onRemove`, but catching
/// the opposite half of a value's lifecycle: `.onRemove` sees a node vanish
/// entirely; `.onChange` sees it stay declared with a *different* value,
/// which `.onRemove` alone can't — same identity, so `endPass` never treats
/// it as removed.
public struct _OnChangeModifier<Content: XView, Value: Equatable>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let value: Value
    let action: (Value?, Value) -> Void

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let box: StateStore.Box<Value?> = store.box(for: id.child(type: Self.self)) { nil }
        if box.value != value {
            action(box.value, value)
            box.value = value
        }
        return lower(content, id: id, store: store)
    }
}

public extension XView {
    /// Run `action(old, new)` whenever `value` differs from what this node
    /// last declared — including the first declaration, where `old` is `nil`.
    func onChange<Value: Equatable>(of value: Value, perform action: @escaping (Value?, Value) -> Void) -> _OnChangeModifier<Self, Value> {
        _OnChangeModifier(content: self, value: value, action: action)
    }
}
