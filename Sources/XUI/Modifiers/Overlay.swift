import Foundation

struct DecorationLayout: NodeLayout {
    enum Kind {
        case background
        case overlay
    }

    var kind: Kind
    var alignment: Alignment
    var contentIsUnwrapped = false
    var decorationIsUnwrapped = false

    /// A single child can use the same proposals and frames without a separate
    /// passthrough node. Empty and multi-child groups still need group layout.
    static func grouped(kind: Kind, alignment: Alignment, content: [LayoutNode], decoration: [LayoutNode]) -> LayoutNode {
        let contentNode = group(content)
        let decorationNode = group(decoration)
        return LayoutNode(
            layout: Self(kind: kind, alignment: alignment,
                         contentIsUnwrapped: content.count == 1, decorationIsUnwrapped: decoration.count == 1),
            children: kind == .background ? [decorationNode, contentNode] : [contentNode, decorationNode]
        )
    }

    private static func group(_ children: [LayoutNode]) -> LayoutNode {
        if children.count == 1 { return children[0] }
        return LayoutNode(layout: PassthroughLayout(), children: children)
    }

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
        return measure(children[contentIndex], proposal, context, unwrapped: contentIsUnwrapped)
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        guard children.indices.contains(contentIndex) else { return }
        place(children[contentIndex], in: rect, context, unwrapped: contentIsUnwrapped)

        guard children.indices.contains(decorationIndex) else { return }
        let decoration = children[decorationIndex]
        let size = measure(decoration, ProposedSize(rect.size), context, unwrapped: decorationIsUnwrapped)
        place(decoration, in: alignment.position(size, in: rect), context, unwrapped: decorationIsUnwrapped)
    }

    private func measure(_ node: LayoutNode, _ proposal: ProposedSize, _ context: LayoutContext, unwrapped: Bool) -> Size {
        let size = node.measure(proposal, context)
        if unwrapped {
            // PassthroughLayout takes the component-wise maximum starting at zero.
            return Size(width: max(0, size.width), height: max(0, size.height))
        }
        return size
    }

    private func place(_ node: LayoutNode, in rect: Rect, _ context: LayoutContext, unwrapped: Bool) {
        // A passthrough node remeasures its child against its own final frame.
        let size = unwrapped ? node.measure(ProposedSize(rect.size), context) : rect.size
        node.frame = Rect(origin: rect.origin, size: size)
    }
}

public struct _BackgroundModifier<Content: XView, Background: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let background: Background
    let alignment: Alignment

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let backgroundNodes = await lower(background, id: id.child(type: Background.self, index: 0), store: store)
        let contentNodes = await lower(content, id: id.child(type: Content.self, index: 1), store: store)
        return [DecorationLayout.grouped(kind: .background, alignment: alignment, content: contentNodes, decoration: backgroundNodes)]
    }
}

public struct _OverlayModifier<Content: XView, Overlay: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let overlay: Overlay
    let alignment: Alignment

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let contentNodes = await lower(content, id: id.child(type: Content.self, index: 0), store: store)
        let overlayNodes = await lower(overlay, id: id.child(type: Overlay.self, index: 1), store: store)
        return [DecorationLayout.grouped(kind: .overlay, alignment: alignment, content: contentNodes, decoration: overlayNodes)]
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
