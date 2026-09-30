import XRender
import XUI

/// A texture-backed image leaf for SceneKit-backed XUI trees.
///
/// It behaves like SwiftUI's `Image`: it reports its natural size until
/// `.resizable()` is applied. Use `.resizable().scaledToFit()` /
/// `.resizable().scaledToFill()` to preserve the natural aspect while scaling.
public struct SpriteImage: ScenePrimitive {
    public typealias Body = Never
    enum Resizing: Sendable {
        case fixed
        case resizable
    }

    public var texture: TextureID
    public var naturalSize: XUI.Size
    public var source: RenderRect?
    public var tint: RenderColor
    public var opacity: Float
    public var layer: RenderLayer?
    var resizing: Resizing

    public init(
        _ texture: TextureID,
        naturalSize: XUI.Size,
        source: RenderRect? = nil,
        tint: RenderColor = .white,
        opacity: Float = 1,
        layer: RenderLayer? = nil
    ) {
        self.texture = texture
        self.naturalSize = naturalSize
        self.source = source
        self.tint = tint
        self.opacity = opacity
        self.layer = layer
        self.resizing = .fixed
    }

    public init(
        _ texture: TextureID,
        naturalSize: SIMD2<Float>,
        source: RenderRect? = nil,
        tint: RenderColor = .white,
        opacity: Float = 1,
        layer: RenderLayer? = nil
    ) {
        self.init(
            texture,
            naturalSize: XUI.Size(width: Double(naturalSize.x), height: Double(naturalSize.y)),
            source: source,
            tint: tint,
            opacity: opacity,
            layer: layer
        )
    }

    public func sizeThatFits(_ proposal: XUI.ProposedSize) -> XUI.Size {
        switch resizing {
        case .fixed:
            naturalSize
        case .resizable:
            proposal.resolved(fallback: naturalSize)
        }
    }

    public func draw(in rect: XUI.Rect, builder: inout SceneBuilder, context _: RenderContext) {
        builder.sprite(
            texture,
            in: rect.render,
            source: source,
            tint: tint,
            opacity: opacity,
            layer: layer
        )
    }

    public func resizable() -> Self {
        var copy = self
        copy.resizing = .resizable
        return copy
    }

    public func tint(_ color: RenderColor) -> Self {
        var copy = self
        copy.tint = color
        return copy
    }

    public func opacity(_ amount: Float) -> Self {
        var copy = self
        copy.opacity = amount
        return copy
    }

    public func layer(_ layer: RenderLayer?) -> Self {
        var copy = self
        copy.layer = layer
        return copy
    }
}
