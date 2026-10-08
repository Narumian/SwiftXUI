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
