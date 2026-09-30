import Foundation

/// A purely visual translation: layout size is unchanged, the content is drawn
/// shifted. Mirrors SwiftUI's `.offset`.
struct OffsetLayout: NodeLayout {
    var dx: Double
    var dy: Double

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        children.first.map { LayoutEngine.measure($0, proposal, context) } ?? .zero
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        guard let child = children.first else { return }
        child.frame = rect.offsetBy(dx: dx, dy: dy)
    }
}

public struct _OffsetModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let dx: Double
    let dy: Double

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        // Inside `.animation(_:value:)` the offset eases to its new value.
        let shown = store.animated(Point(x: dx, y: dy), id: id.child(type: Self.self, index: 1))
        return [LayoutNode(layout: OffsetLayout(dx: shown.x, dy: shown.y),
                           children: await lower(content, id: id, store: store))]
    }
}

public extension XView {
    func offset(x: Double = 0, y: Double = 0) -> _OffsetModifier<Self> {
        _OffsetModifier(content: self, dx: x, dy: y)
    }
}
