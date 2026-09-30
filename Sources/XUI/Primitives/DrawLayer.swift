import Foundation

/// The escape hatch. A leaf that reports a size and hands its resolved rect
/// straight to imperative drawing code — no view wrapping for reel spins,
/// particle fields, slashes and other per-frame juice.
///
/// By default it fills whatever space it is offered (like `Color`); pass a
/// `size` closure when the leaf's extent depends on what it will draw.
public struct DrawLayer: XView, _PrimitiveXView {
    public typealias Body = Never

    let sizing: (ProposedSize) -> Size
    let draw: (Rect, RenderContext) -> Void

    /// Fills the offered space. You paint inside `rect`; `context` carries the
    /// canvas, the environment (animation clock, fx state) and `hitRegion`.
    public init(_ draw: @escaping (_ rect: Rect, _ context: RenderContext) -> Void) {
        self.sizing = { $0.resolved(fallback: Size(width: 10, height: 10)) }
        self.draw = draw
    }

    /// Reports `size(proposal)` and paints within it.
    public init(
        size: @escaping (ProposedSize) -> Size,
        draw: @escaping (_ rect: Rect, _ context: RenderContext) -> Void
    ) {
        self.sizing = size
        self.draw = draw
    }

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let node = LayoutNode(layout: DrawLayerLayout(sizing: sizing))
        node.draw = draw
        return [node]
    }
}

struct DrawLayerLayout: NodeLayout {
    var sizing: (ProposedSize) -> Size

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        sizing(proposal)
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {}
}
