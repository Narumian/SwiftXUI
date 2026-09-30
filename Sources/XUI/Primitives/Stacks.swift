import Foundation

/// Lay children out left-to-right.
public struct HStack<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    var alignment: VerticalAlignment
    var spacing: Double
    var content: Content

    public init(
        alignment: VerticalAlignment = .center,
        spacing: Double = 0,
        @XViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let layout = StackLayout(axis: .horizontal, spacing: spacing, crossFraction: alignment.fraction)
        return [LayoutNode(layout: layout, children: await lower(content, id: id, store: store))]
    }
}

/// Lay children out top-to-bottom.
public struct VStack<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    var alignment: HorizontalAlignment
    var spacing: Double
    var content: Content

    public init(
        alignment: HorizontalAlignment = .center,
        spacing: Double = 0,
        @XViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let layout = StackLayout(axis: .vertical, spacing: spacing, crossFraction: alignment.fraction)
        return [LayoutNode(layout: layout, children: await lower(content, id: id, store: store))]
    }
}

/// Overlay children, back to front, aligned within the stack's bounds.
public struct ZStack<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    var alignment: Alignment
    var content: Content

    public init(
        alignment: Alignment = .center,
        @XViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.content = content()
    }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        [LayoutNode(layout: ZStackLayout(alignment: alignment), children: await lower(content, id: id, store: store))]
    }
}
