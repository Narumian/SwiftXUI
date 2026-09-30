import Foundation

struct DecorationLayout: NodeLayout {
    enum Kind {
        case background
        case overlay
    }

    var kind: Kind
    var alignment: Alignment

    private var contentIndex: Int {
        switch kind {
        case .background: return 1
        case .overlay: return 0
        }
    }

    private var decorationIndex: Int {
        switch kind {
        case .background: return 0
        case .overlay: return 1
        }
    }

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        guard children.indices.contains(contentIndex) else { return .zero }
        return LayoutEngine.measure(children[contentIndex], proposal, context)
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        guard children.indices.contains(contentIndex) else { return }
        children[contentIndex].frame = rect

        guard children.indices.contains(decorationIndex) else { return }
        let decoration = children[decorationIndex]
        let size = LayoutEngine.measure(decoration, ProposedSize(rect.size), context)
        decoration.frame = alignment.position(size, in: rect)
    }
}

public struct _BackgroundModifier<Content: XView, Background: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let background: Background
    let alignment: Alignment

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let backgroundNode = LayoutNode(layout: PassthroughLayout(),
                                        children: await lower(background, id: id.child(type: Background.self, index: 0), store: store))
        let contentNode = LayoutNode(layout: PassthroughLayout(),
                                     children: await lower(content, id: id.child(type: Content.self, index: 1), store: store))
        return [
            LayoutNode(
                layout: DecorationLayout(kind: .background, alignment: alignment),
                children: [backgroundNode, contentNode]
            )
        ]
    }
}

public struct _OverlayModifier<Content: XView, Overlay: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let overlay: Overlay
    let alignment: Alignment

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let contentNode = LayoutNode(layout: PassthroughLayout(),
                                     children: await lower(content, id: id.child(type: Content.self, index: 0), store: store))
        let overlayNode = LayoutNode(layout: PassthroughLayout(),
                                     children: await lower(overlay, id: id.child(type: Overlay.self, index: 1), store: store))
        return [
            LayoutNode(
                layout: DecorationLayout(kind: .overlay, alignment: alignment),
                children: [contentNode, overlayNode]
            )
        ]
    }
}

public extension XView {
    func background<Background: XView>(
        alignment: Alignment = .center,
        @XViewBuilder _ background: () -> Background
    ) -> _BackgroundModifier<Self, Background> {
        _BackgroundModifier(content: self, background: background(), alignment: alignment)
    }

    func overlay<Overlay: XView>(
        alignment: Alignment = .center,
        @XViewBuilder _ overlay: () -> Overlay
    ) -> _OverlayModifier<Self, Overlay> {
        _OverlayModifier(content: self, overlay: overlay(), alignment: alignment)
    }
}
