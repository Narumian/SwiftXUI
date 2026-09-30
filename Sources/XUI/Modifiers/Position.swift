import Foundation

/// Place this view's centre at `(x, y)` in the parent's coordinate space,
/// ignoring the parent's own placement. Layout-affecting: the resolved frame
/// (and any `.anchor`) reflects the new position. Mirrors SwiftUI's `.position`.
///
/// The view still reports its natural size to its parent (so a stack leaves a
/// slot for it); only where it lands changes.
struct PositionLayout: NodeLayout {
    var x: Double
    var y: Double

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        children.first.map { $0.measure(proposal, context) } ?? .zero
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        guard let child = children.first else { return }
        let size = child.measure(ProposedSize(rect.size), context)
        child.frame = Rect(x: rect.x + x - size.width / 2, y: rect.y + y - size.height / 2,
                           width: size.width, height: size.height)
    }
}

public struct _PositionModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let x: Double
    let y: Double

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        [LayoutNode(layout: PositionLayout(x: x, y: y), children: await lower(content, id: id, store: store))]
    }
}

public extension XView {
    /// Centre this view at `(x, y)` in the parent's space.
    func position(x: Double, y: Double) -> _PositionModifier<Self> {
        _PositionModifier(content: self, x: x, y: y)
    }

    func position(_ point: Point) -> _PositionModifier<Self> {
        _PositionModifier(content: self, x: point.x, y: point.y)
    }
}
