import Foundation

/// A directional-focus target that hands its focus state to the content so the
/// caller can draw its own focused look instead of the stock ring.
public struct FocusStateView<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never

    let control: XControl
    let content: @Sendable (Bool) -> Content

    public init(
        id: ControlID,
        label: String,
        @XViewBuilder content: @escaping @Sendable (_ isFocused: Bool) -> Content
    ) {
        self.control = XControl(id: id, label: label)
        self.content = content
    }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let selected = _EnvironmentObjectContext.currentOrEmpty
            .object(FocusStore.self)?
            .selectedID == control.id
        let view = content(selected)
        let node = LayoutNode(
            layout: PassthroughLayout(),
            children: await lower(view, id: id.child(type: Content.self), store: store)
        )
        node.control = control
        return [node]
    }
}

/// Hands the host's currently focused control ID to the content, without registering a
/// control of its own. Use it to make one region of a screen follow focus elsewhere.
public struct FocusReader<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never

    let content: @XUIActor @Sendable (ControlID?) -> Content

    public init(@XViewBuilder content: @XUIActor @escaping @Sendable (_ focused: ControlID?) -> Content) {
        self.content = content
    }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let selected = _EnvironmentObjectContext.currentOrEmpty
            .object(FocusStore.self)?
            .selectedID
        let view = content(selected)
        return [LayoutNode(
            layout: PassthroughLayout(),
            children: await lower(view, id: id.child(type: Content.self), store: store)
        )]
    }
}
