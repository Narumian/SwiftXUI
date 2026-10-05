import Foundation

/// Makes a view available to directional focus navigation and draws a focus
/// ring while its control ID is selected by the host.
public struct _FocusableModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never

    let content: Content
    let control: XControl
    let ringColor: XColorValue
    let ringWidth: Double
    let cornerRadius: Double

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let contentNode = LayoutNode(
            layout: PassthroughLayout(),
            children: await lower(content, id: id.child(type: Content.self), store: store)
        )
        contentNode.control = control

        let selected = _EnvironmentObjectContext.currentOrEmpty
            .object(FocusStore.self)?
            .selectedID == control.id
        let ring = LayoutNode(layout: FillLayout())
        if selected {
            let color = ringColor
            let width = ringWidth
            let radius = cornerRadius
            ring.draw = { rect, context in
                context.canvas.strokeRoundedRect(
                    rect.inset(by: EdgeInsets(width / 2)),
                    cornerRadius: max(0, radius - width / 2),
                    color: color,
                    lineWidth: width
                )
            }
        }

        return [LayoutNode(
            layout: DecorationLayout(kind: .overlay, alignment: .center),
            children: [contentNode, ring]
        )]
    }
}

public extension XView {
    /// Register a view as a directional-focus target.
    func focusable(
        id: String,
        label: String,
        ringColor: XColorValue = XColorValue(0.1, 0.85, 1),
        ringWidth: Double = 3,
        cornerRadius: Double = 12
    ) -> _FocusableModifier<Self> {
        focusable(
            id: ControlID(rawValue: id),
            label: label,
            ringColor: ringColor,
            ringWidth: ringWidth,
            cornerRadius: cornerRadius
        )
    }

    /// Register a view as a directional-focus target with an existing ID.
    func focusable(
        id: ControlID,
        label: String,
        ringColor: XColorValue = XColorValue(0.1, 0.85, 1),
        ringWidth: Double = 3,
        cornerRadius: Double = 12
    ) -> _FocusableModifier<Self> {
        _FocusableModifier(
            content: self,
            control: XControl(id: id, label: label),
            ringColor: ringColor,
            ringWidth: ringWidth,
            cornerRadius: cornerRadius
        )
    }
}
