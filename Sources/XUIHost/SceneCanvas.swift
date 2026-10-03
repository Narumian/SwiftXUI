import Foundation
import XRender
import XShader
import XUI

/// A `XUI.XCanvas` backed by XRender's `SceneBuilder`. Build one per
/// frame, hand it to `LayoutHost.render`, then read `.scene`.
///
/// `SceneBuilder` is a value type built up imperatively; this reference wrapper
/// lets the layout walk share one accumulator across every leaf's draw call.
public final class SceneCanvas: XUI.XCanvas, XUI.ShaderSink, XUI.LayerShaderSink {
    public internal(set) var builder: SceneBuilder
    private var layerStack: [(shader: AnyShader, rect: XUI.Rect, builder: SceneBuilder)] = []
    /// Supplies atlas metrics so `Text` sizing matches what the compiler draws.
    public var fonts: FontBook?
    /// Resolves renderer-agnostic `XUI.Image` sources into XRender textures.
    public var images: [ImageSource: TextureID]
    /// Layer every XUI primitive paints into unless a leaf overrides it.
    public var layer: RenderLayer

    public init(
        size: RenderSize,
        background: RenderColor = RenderColor(0, 0, 0, 0),
        fonts: FontBook? = nil,
        images: [ImageSource: TextureID] = [:],
        layer: RenderLayer = .ui
    ) {
        self.builder = SceneBuilder(size: size, background: background)
        self.fonts = fonts
        self.images = images
        self.layer = layer
    }

    /// The accumulated scene. Read once, after `LayoutHost.render`.
    public var scene: Scene { builder.scene }

    public func submit(shaders: [XUI.ResolvedShader]) {
        // `.layer` shaders were emitted by the bracketed render walk above.
        // Remaining scopes retain the legacy renderer-neutral region export.
        for resolved in shaders where resolved.shader.scope != .layer {
            builder.shader(resolved.shader, in: resolved.rect.render)
        }
    }

    public func beginLayerShader(_ shader: AnyShader, in rect: XUI.Rect) {
        let parent = builder
        layerStack.append((shader: shader, rect: rect, builder: parent))
        // The offscreen layer starts transparent; its commands use the same
        // authoring coordinates as its parent, so no layout translation leaks.
        builder = SceneBuilder(size: parent.scene.authoringCanvas ?? RenderSize(
            width: Float(rect.width), height: Float(rect.height)
        ), background: RenderColor(0, 0, 0, 0))
    }

    public func endLayerShader() {
        guard let scope = layerStack.popLast() else { return }
        let child = builder.scene
        builder = scope.builder
        builder.shaderLayer(scope.shader, in: scope.rect.render, commands: child.commands)
    }

    // MARK: XCanvas

    public func fillRect(_ rect: XUI.Rect, color: XColorValue) {
        builder.rect(rect.render, color: color.render, layer: layer)
    }

    public func fillRoundedRect(_ rect: XUI.Rect, cornerRadius: Double, color: XColorValue) {
        builder.rect(rect.render, color: color.render, corner: Float(cornerRadius), layer: layer)
    }

    public func strokeRoundedRect(
        _ rect: XUI.Rect,
        cornerRadius: Double,
        color: XColorValue,
        lineWidth: Double
    ) {
        let points = roundedRectStrokePoints(in: rect, cornerRadius: cornerRadius)
        guard points.count >= 2 else { return }
        builder.polyline(
            points.map(\.render),
            width: Float(max(0, lineWidth)),
            closed: true,
            color: color.render,
            layer: layer
        )
    }

    public func fillEllipse(in rect: XUI.Rect, color: XColorValue) {
        builder.ellipse(
            center: RenderPoint(x: Float(rect.midX), y: Float(rect.midY)),
            radiusX: Float(rect.width / 2),
            radiusY: Float(rect.height / 2),
            color: color.render,
            layer: layer
        )
    }

    public func fillPath(_ path: XUI.Path, in rect: XUI.Rect, color: XColorValue) {
        for subpath in path.subpaths(fittedIn: rect) where subpath.points.count >= 3 {
            builder.polygon(subpath.points.map(\.render), color: color.render, layer: layer)
        }
    }

    public func strokePath(_ path: XUI.Path, in rect: XUI.Rect, color: XColorValue, lineWidth: Double) {
        for subpath in path.subpaths(fittedIn: rect) where subpath.points.count >= 2 {
            builder.polyline(
                subpath.points.map(\.render),
                width: Float(max(0, lineWidth)),
                closed: subpath.closed,
                color: color.render,
                layer: layer
            )
        }
    }

    public func drawImage(_ source: ImageSource, in rect: XUI.Rect, opacity: Double) {
        guard let texture = images[source] ?? source.textureID else { return }
        builder.sprite(texture, in: rect.render, opacity: Float(opacity), layer: layer)
    }

    public func drawText(
        _ string: String,
        in rect: XUI.Rect,
        fontSize: Double,
        font: TextFont,
        color: XColorValue,
        alignment: HorizontalAlignment,
        outline: TextOutline?
    ) {
        // XRender's text scale uses a seven-unit cap-height em, while XUI's
        // public Text API expresses sizes in logical points. Keep the bridge
        // in one place so a Text(size: 20) is a 20-point label rather than a
        // 140-point label when a font atlas is installed.
        let scale = Self.renderScale(for: fontSize)
        let font = font.render
        let width = builder.textWidth(string, scale: scale, font: font, fonts: fonts)
        let originX: Float
        switch alignment {
        case .leading: originX = Float(rect.x)
        case .center: originX = Float(rect.midX) - width / 2
        case .trailing: originX = Float(rect.maxX) - width
        }
        let origin = RenderPoint(x: originX, y: Float(rect.y))
        let outlineWidth = Float(outline?.width ?? 0)
        let outlineColor: RenderColor
        if let outline, outline.width > 0, outline.color.opacity > 0 {
            outlineColor = outline.color.render.withAlpha(Float(outline.color.opacity * color.opacity))
        } else {
            outlineColor = RenderColor(0, 0, 0, 0)
        }
        builder.text(string, at: origin, scale: scale, color: color.render, layer: layer, font: font,
                     outline: outlineWidth, outlineColor: outlineColor)
    }

    public func pushTransform(_ transform: XTransform) {
        builder.pushTransform(transform.render)
    }

    public func popTransform() {
        builder.popTransform()
    }

    public func pushClip(_ rect: XUI.Rect) {
        builder.pushClip(rect.render)
    }

    public func popClip() {
        builder.popClip()
    }

    public func measureText(_ string: String, fontSize: Double, font: TextFont) -> XUI.Size {
        let scale = Self.renderScale(for: fontSize)
        let font = font.render
        let width = builder.textWidth(string, scale: scale, font: font, fonts: fonts)
        // One line: atlas line-height in logical units when a font is loaded,
        // else the vector font's ~9-unit em (7 cap + descender + leading).
        let height: Float
        if let atlas = fonts?[font] {
            height = atlas.lineHeight * atlas.drawScale(scale)
        } else {
            height = scale * 9
        }
        return XUI.Size(width: Double(width), height: Double(height))
    }

    private static func renderScale(for fontSize: Double) -> Float {
        Float(max(0, fontSize) / 7)
    }

    private func roundedRectStrokePoints(in rect: XUI.Rect, cornerRadius: Double) -> [XUI.Point] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let radius = min(max(0, cornerRadius), rect.width / 2, rect.height / 2)
        guard radius > 0 else {
            return [
                XUI.Point(x: rect.minX, y: rect.minY),
                XUI.Point(x: rect.maxX, y: rect.minY),
                XUI.Point(x: rect.maxX, y: rect.maxY),
                XUI.Point(x: rect.minX, y: rect.maxY)
            ]
        }

        let segments = 5
        let corners: [(center: XUI.Point, start: Double, end: Double)] = [
            (XUI.Point(x: rect.maxX - radius, y: rect.minY + radius), -.pi / 2, 0),
            (XUI.Point(x: rect.maxX - radius, y: rect.maxY - radius), 0, .pi / 2),
            (XUI.Point(x: rect.minX + radius, y: rect.maxY - radius), .pi / 2, .pi),
            (XUI.Point(x: rect.minX + radius, y: rect.minY + radius), .pi, .pi * 1.5)
        ]

        return corners.flatMap { corner in
            (0...segments).map { index in
                let t = Double(index) / Double(segments)
                let angle = corner.start + (corner.end - corner.start) * t
                return XUI.Point(
                    x: corner.center.x + cos(angle) * radius,
                    y: corner.center.y + sin(angle) * radius
                )
            }
        }
    }
}
