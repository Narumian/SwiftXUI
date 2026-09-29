import Foundation

/// `View.animation(_:value:)`: when `value` changes, animatable values inside
/// move with `animation` instead of jumping. Pass `nil` to make everything
/// inside jump.
public struct _AnimationModifier<Content: XView, Value: Equatable>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let animation: Animation?
    let value: Value

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let previous: StateStore.Box<Value?> = store.box(for: id.child(type: Self.self, index: 0)) { nil }
        // The first frame is not a change: nothing animates in.
        let triggered = previous.value.map { $0 != value } ?? false
        previous.value = value

        let saved = store.transaction
        store.transaction = Transaction(animation: animation, triggered: triggered)
        defer { store.transaction = saved }
        return lower(content, id: id, store: store)
    }
}

public extension XView {
    /// Animates the animatable values inside this view (sizes, offsets) when
    /// `value` changes, using the host's presentation clock (`fxTime`).
    ///
    ///     RoundedRectangle(cornerRadius: 6, fill: .red)
    ///         .frame(width: barWidth * fraction, height: 14)
    ///         .animation(.easeOut(duration: 0.4), value: health)
    func animation<Value: Equatable>(_ animation: Animation?, value: Value) -> _AnimationModifier<Self, Value> {
        _AnimationModifier(content: self, animation: animation, value: value)
    }
}
