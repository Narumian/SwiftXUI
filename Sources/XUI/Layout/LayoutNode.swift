import Foundation
import XShader

/// Ambient state threaded through both layout passes. Currently just the
/// environment (so `Text` can reach the text measurer); a natural home for a
/// layout-direction flip or a debug flag later.
struct LayoutContext {
    var environment: EnvironmentValues
    /// What `Length.fraction` is a fraction of: the canvas being laid out.
    var referenceSize: Size = .zero
    /// Which layout pass this is. A node remembers the sizes it measured only
    /// for the pass that measured them (see `LayoutNode.measure`).
    var pass: UInt64 = 0
}

/// Hands out a fresh pass number per `LayoutHost` walk. Layout is single
/// threaded, one pass at a time.
enum LayoutPass {
    nonisolated(unsafe) private static var last: UInt64 = 0
    static func next() -> UInt64 {
        last &+= 1
        return last
    }
}

/// A resolved node in the layout tree. One is created per primitive during
/// lowering; composites contribute none of their own (they expand to their
/// `body`'s nodes). Reference type so the two-pass engine can write `frame`
/// back in place.
final class LayoutNode {
    /// How this node measures itself and positions its children.
    var layout: any NodeLayout {
        didSet { forgetSizes() }
    }
    /// Direct children, already lowered.
    var children: [LayoutNode] {
        didSet { forgetSizes() }
    }
    /// Filled by the place pass, in absolute canvas coordinates.
    var frame: Rect = .zero

    /// Draw callback for leaves that paint (`Color`, `Text`, `DrawLayer`).
    var draw: ((Rect, RenderContext) -> Void)?
    /// Named-rect export set by `.anchor(_:)`.
    var anchor: AnchorID?
    /// Hit-region payload set by `.region(_:)` / `.onTapGesture(_:)`.
    var region: AnyHashable?
    /// Semantic action target set by `.control(_:)`.
    var control: XControl?
    /// Tap action set by `.onTapGesture { ... }`.
    var tapGesture: (() -> Void)?
    var tapGestureID: String?
    var tapGestureLabel: String?
    /// Drag gesture registered by `.gesture(DragGesture(...))`.
    var dragGesture: DragGesture?
    /// Register `tapGesture` after the children so anything inside wins the
    /// first-match hit test (a scrim behind a sheet's content).
    var tapGestureAfterChildren = false
    /// This subtree paints but contributes no regions, controls or taps (the
    /// screen behind a presented sheet).
    var blocksInput = false
    /// Every control in this subtree reports this focus scope.
    var focusScopeOverride: FocusScopeID?
    /// `Spacer` marker. A stack treats such a child as flexible on its own main
    /// axis (`[spacerMinLength, ∞]`) and zero on the cross axis.
    var isSpacer = false
    var spacerMinLength: Double = 0
    /// Render-only transform scoped to this node's subtree (`.transform(_:)`).
    var transform: XTransform?
    /// Render-only transform that depends on this node's resolved frame
    /// (`.rotationEffect(_, anchor:)`, `.scaleEffect(anchor:)`).
    var transformInFrame: ((Rect) -> XTransform)?
    /// Shader applied to this node's rendered subtree. Like transforms, this
    /// never affects measurement or placement.
    var shader: AnyShader?
    /// Render-only clipping scoped to this node's resolved frame.
    var clipsToBounds = false
    /// A scrolling viewport exported for focus-driven auto-scrolling.
    var scrollViewportID: String?
    /// Content that can only be built once the node's resolved frame is known
    /// (`GeometryReader`). The engine runs this during `place`.
    var lazyChildren: (@XUIActor (Rect, LayoutContext) async -> [LayoutNode])?

    private var measuredSizes: [ProposedSize: Size] = [:]
    private var measuredPass: UInt64 = .max

    private func forgetSizes() {
        if !measuredSizes.isEmpty { measuredSizes.removeAll(keepingCapacity: true) }
    }

    /// `layout.sizeThatFits`, remembered per proposal for the rest of the pass.
    /// A stack asks each child for its size several times (flexibility probes at
    /// 0 and ∞, then the share it hands out, then again to place), and every
    /// child does the same to its own children, so without this the number of
    /// measurements multiplies with each level of nesting. `NodeLayout` is
    /// documented as pure, so the answer cannot change within a pass.
    func measure(_ proposal: ProposedSize, _ context: LayoutContext) -> Size {
        if measuredPass != context.pass {
            measuredSizes.removeAll(keepingCapacity: true)
            measuredPass = context.pass
        }
        if let known = measuredSizes[proposal] { return known }
        let size = layout.sizeThatFits(proposal, children, context)
        measuredSizes[proposal] = size
        return size
    }

    init(layout: any NodeLayout, children: [LayoutNode] = []) {
        self.layout = layout
        self.children = children
    }
}

/// The measure/place contract. Implementations must be pure functions of their
/// inputs — the engine may call `sizeThatFits` several times per node.
protocol NodeLayout {
    /// Return the size this node wants, given what the parent offers.
    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size
    /// Set `child.frame` (absolute) for every direct child. Do **not** recurse —
    /// the engine walks grandchildren.
    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext)
}

extension NodeLayout {
    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        // Default: hand the whole rect to each child (ZStack-style overlay).
        for child in children {
            let size = child.measure(ProposedSize(rect.size), context)
            child.frame = Alignment.center.position(size, in: rect)
        }
    }
}
