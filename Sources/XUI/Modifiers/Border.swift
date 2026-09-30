import Foundation

public struct _BorderModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let color: XColorValue
    let width: Double
    let cornerRadius: Double

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let contentNode = LayoutNode(layout: PassthroughLayout(),
                                     children: await lower(content, id: id.child(type: Content.self, index: 0), store: store))
        let borderNode = (await _BorderView(color: color, width: width, cornerRadius: cornerRadius)
            ._lower(id: id.child(type: _BorderView.self, index: 1), store: store))[0]
        return [
            LayoutNode(
                layout: DecorationLayout(kind: .overlay, alignment: .center),
                children: [contentNode, borderNode]
            )
        ]
    }
}

private struct _BorderView: XView, _PrimitiveXView {
    typealias Body = Never
    var color: XColorValue
    var width: Double
    var cornerRadius: Double

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let node = LayoutNode(layout: FillLayout())
        let color = color
        let width = width
        let cornerRadius = cornerRadius
        node.draw = { rect, context in
            guard width > 0, color.opacity > 0 else { return }
            context.canvas.strokeRoundedRect(
                rect.inset(by: EdgeInsets(width / 2)),
                cornerRadius: max(0, cornerRadius - width / 2),
                color: color,
                lineWidth: width
            )
        }
        return [node]
    }
}

public extension XView {
    /// Draw a border over this view without changing layout.
    func border(
        _ color: XColorValue,
        width: Double = 1,
        cornerRadius: Double = 0
    ) -> _BorderModifier<Self> {
        _BorderModifier(content: self, color: color, width: width, cornerRadius: cornerRadius)
    }
}
