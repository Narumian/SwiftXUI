import Foundation

struct PaddingLayout: NodeLayout {
    var insets: EdgeInsets

    private var horizontal: Double { insets.leading + insets.trailing }
    private var vertical: Double { insets.top + insets.bottom }

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        guard let child = children.first else {
            return Size(width: horizontal, height: vertical)
        }
        let inner = ProposedSize(
            width: proposal.width.map { max(0, $0 - horizontal) },
            height: proposal.height.map { max(0, $0 - vertical) }
        )
        let childSize = LayoutEngine.measure(child, inner, context)
        return Size(width: childSize.width + horizontal, height: childSize.height + vertical)
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        guard let child = children.first else { return }
        child.frame = rect.inset(by: insets)
    }
}

/// Pads by the environment's safe-area insets on the chosen edges.
struct SafeAreaPaddingLayout: NodeLayout {
    var edges: Edge

    private func insets(_ context: LayoutContext) -> EdgeInsets {
        let safe = context.environment.safeAreaInsets
        return EdgeInsets(top: edges.contains(.top) ? safe.top : 0,
                          leading: edges.contains(.leading) ? safe.leading : 0,
                          bottom: edges.contains(.bottom) ? safe.bottom : 0,
                          trailing: edges.contains(.trailing) ? safe.trailing : 0)
    }

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        PaddingLayout(insets: insets(context)).sizeThatFits(proposal, children, context)
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        PaddingLayout(insets: insets(context)).placeChildren(in: rect, children, context)
    }
}

public struct _SafeAreaPaddingModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let edges: Edge

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        [LayoutNode(layout: SafeAreaPaddingLayout(edges: edges), children: await lower(content, id: id, store: store))]
    }
}

public struct _PaddingModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let insets: EdgeInsets

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        [LayoutNode(layout: PaddingLayout(insets: insets), children: await lower(content, id: id, store: store))]
    }
}

public extension XView {
    /// Inset on every edge by the same amount.
    func padding(_ length: Double) -> _PaddingModifier<Self> {
        _PaddingModifier(content: self, insets: EdgeInsets(length))
    }

    /// Inset only the named edges.
    func padding(_ edges: Edge, _ length: Double) -> _PaddingModifier<Self> {
        _PaddingModifier(content: self, insets: edges.insets(length))
    }

    /// Keep clear of the host's safe area (`EnvironmentValues.safeAreaInsets`).
    func safeAreaPadding(_ edges: Edge = .all) -> _SafeAreaPaddingModifier<Self> {
        _SafeAreaPaddingModifier(content: self, edges: edges)
    }

    /// Inset per edge.
    func padding(_ insets: EdgeInsets) -> _PaddingModifier<Self> {
        _PaddingModifier(content: self, insets: insets)
    }
}
