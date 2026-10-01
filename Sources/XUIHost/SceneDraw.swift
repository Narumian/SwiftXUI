import XRender
import XUI

public extension SceneCanvas {
    /// Mutate the accumulating `SceneBuilder` in place.
    func draw(_ body: (inout SceneBuilder) -> Void) {
        body(&builder)
    }
}

/// A convenient one-off `ScenePrimitive` that hands imperative code a real
/// `inout SceneBuilder` — the full drawing API (sprites, meshes, gradients,
/// `inLayer` / `clipped` scopes), not just the thin `XCanvas` surface — plus
/// the `RenderContext` for `hitRegion` and the environment. Keep it for whole
/// scene effects; prefer a named `ScenePrimitive` when the leaf is reusable.
///
/// ```swift
/// SceneDraw { rect, b, ctx in
///     b.rect(rect.render, color: .white)
///     ctx.hitRegion(rect, PlayerAction.spin)
/// }
/// .anchor("screen")
/// ```
/// SceneKit's intrinsic primitive contract. Reusable GPU components conform
/// to this instead of putting a `SceneDraw` closure in every `body`.
public protocol ScenePrimitive: XUI.IntrinsicView {
    /// Paint through the full SceneBuilder API.
    func draw(in rect: XUI.Rect, builder: inout SceneBuilder, context: RenderContext)
}

public extension ScenePrimitive {
    /// Scene primitives that have no natural extent fill their offered slot,
    /// matching `DrawLayer` / `Color`.
    func sizeThatFits(_ proposal: XUI.ProposedSize) -> XUI.Size {
        proposal.resolved(fallback: XUI.Size(width: 10, height: 10))
    }

    func draw(in rect: XUI.Rect, context: RenderContext) {
        guard let canvas = context.canvas as? SceneCanvas else { return }
        canvas.draw { builder in
            draw(in: rect, builder: &builder, context: context)
        }
    }
}

public struct SceneDraw: ScenePrimitive {
    public typealias Body = Never

    let sizing: (@Sendable (XUI.ProposedSize) -> XUI.Size)?
    let paint: @Sendable (XUI.Rect, inout SceneBuilder, RenderContext) -> Void

    /// Fills the offered space.
    public init(
        _ draw: @escaping @Sendable (_ rect: XUI.Rect, _ builder: inout SceneBuilder, _ context: RenderContext) -> Void
    ) {
        self.sizing = nil
        self.paint = draw
    }

    /// Reports an explicit size.
    public init(
        size: @escaping @Sendable (XUI.ProposedSize) -> XUI.Size,
        draw: @escaping @Sendable (_ rect: XUI.Rect, _ builder: inout SceneBuilder, _ context: RenderContext) -> Void
    ) {
        self.sizing = size
        self.paint = draw
    }

    public func sizeThatFits(_ proposal: XUI.ProposedSize) -> XUI.Size {
        sizing?(proposal) ?? proposal.resolved(fallback: XUI.Size(width: 10, height: 10))
    }

    public func draw(in rect: XUI.Rect, builder: inout SceneBuilder, context: RenderContext) {
        // SceneDraw is authored in the leaf's local space. The layout frame
        // remains absolute for anchors and hit testing, but imperative scene
        // commands follow the XView's resolved origin automatically.
        let localRect = XUI.Rect(x: 0, y: 0, width: rect.width, height: rect.height)
        let translation = Transform2D.translation(x: Float(rect.x), y: Float(rect.y))
        context.withDrawingOrigin(rect.origin) {
            builder.transformed(by: translation) { localBuilder in
                paint(localRect, &localBuilder, context)
            }
        }
    }
}
