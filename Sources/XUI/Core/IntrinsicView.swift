import Foundation

/// A leaf view with a reusable intrinsic-size and drawing contract.
///
/// Conform when a component owns one layout rectangle and can paint itself
/// directly. Unlike `DrawLayer`, the component keeps its own type and its
/// sizing rule, so it can be composed, tested, and reused without wrapping a
/// drawing closure at every call site.
public protocol IntrinsicView: XView where Body == Never {
    /// The size this view prefers for `proposal`.
    func sizeThatFits(_ proposal: ProposedSize) -> Size

    /// Paint the view in its resolved layout rectangle.
    func draw(in rect: Rect, context: RenderContext)
}

extension IntrinsicView {
    func _lowerIntrinsicView() -> [LayoutNode] {
        let node = LayoutNode(layout: IntrinsicViewLayout(view: self))
        node.draw = { [self] rect, context in
            draw(in: rect, context: context)
        }
        return [node]
    }
}

private struct IntrinsicViewLayout<View: IntrinsicView>: NodeLayout {
    let view: View

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        view.sizeThatFits(proposal)
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {}
}
