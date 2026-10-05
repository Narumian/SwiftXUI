import Foundation
import XShader

/// Ergonomic front-end for building a `Scene`. Mirrors the old `Canvas` helper
/// names so procedural UI code ports mechanically, but every primitive carries a
/// layer and an optional transform/clip. Characters use `mesh` with a pose;
/// panels, bars and buttons stay procedural shapes.
public struct SceneBuilder {
    public let size: RenderSize
    public private(set) var scene: Scene

    private var layer: RenderLayer = .ui
    private var transform: Transform2D = .identity
    private var clip: RenderRect?

    public init(size: RenderSize, background: RenderColor = RenderColor(0.035, 0.018, 0.055, 1)) {
        self.size = size
        self.scene = Scene(background: background, authoringCanvas: size)
    }

    // MARK: scoping

    public mutating func inLayer(_ layer: RenderLayer, _ body: (inout SceneBuilder) -> Void) {
        let previous = self.layer
        self.layer = layer
        body(&self)
        self.layer = previous
    }

    public mutating func transformed(by t: Transform2D, _ body: (inout SceneBuilder) -> Void) {
        let previous = transform
        transform = t.concatenating(previous)
        body(&self)
        transform = previous
    }

    /// Push/pop form of `transformed(by:)` — for callers that can't wrap their
    /// drawing in a closure (a declarative tree walk). Balance every push.
    private var transformStack: [Transform2D] = []
    public mutating func pushTransform(_ t: Transform2D) {
        transformStack.append(transform)
        transform = t.concatenating(transform)
    }
    public mutating func popTransform() {
        guard let previous = transformStack.popLast() else { return }
        transform = previous
    }

    /// Push/pop form of `clipped(to:)` for declarative tree walks. Nested clips
    /// intersect so children cannot escape an ancestor's clip.
    private var clipStack: [RenderRect?] = []
    public mutating func pushClip(_ rect: RenderRect) {
        clipStack.append(clip)
        clip = clip.map { $0.intersection(rect) } ?? rect
    }
    public mutating func popClip() {
        guard let previous = clipStack.popLast() else { return }
        clip = previous
    }

    public mutating func clipped(to rect: RenderRect, _ body: (inout SceneBuilder) -> Void) {
        let previous = clip
        clip = clip.map { $0.intersection(rect) } ?? rect
        body(&self)
        clip = previous
    }

    // MARK: shapes

    public mutating func rect(_ rect: RenderRect, color: RenderColor, corner: Float = 0, layer: RenderLayer? = nil) {
        shape(.rect(rect, corner: corner), color: color, layer: layer)
    }

    public mutating func circle(center: RenderPoint, radius: Float, color: RenderColor, layer: RenderLayer? = nil) {
        shape(.circle(center: center, radius: radius), color: color, layer: layer)
    }

    public mutating func ellipse(center: RenderPoint, radiusX: Float, radiusY: Float, color: RenderColor, layer: RenderLayer? = nil) {
        shape(.ellipse(center: center, radiusX: radiusX, radiusY: radiusY), color: color, layer: layer)
    }

    public mutating func line(from: RenderPoint, to: RenderPoint, width: Float, color: RenderColor, layer: RenderLayer? = nil) {
        shape(.stroke(points: [from, to], width: width, closed: false), color: color, layer: layer)
    }

    public mutating func polyline(_ points: [RenderPoint], width: Float, closed: Bool = false, color: RenderColor, layer: RenderLayer? = nil) {
        shape(.stroke(points: points, width: width, closed: closed), color: color, layer: layer)
    }

    public mutating func polygon(_ points: [RenderPoint], color: RenderColor, layer: RenderLayer? = nil) {
        shape(.polygon(points: points), color: color, layer: layer)
    }

    public mutating func verticalGradient(_ rect: RenderRect, top: RenderColor, bottom: RenderColor, layer: RenderLayer? = nil) {
        shape(.verticalGradient(rect, top: top, bottom: bottom), color: top, layer: layer)
    }

    /// Pre-tessellated triangles (a `PartedMesh` part), in the part's local
    /// space; `pose` places it.
    public mutating func mesh(_ triangles: [Float], color: RenderColor, pose: Transform2D, layer: RenderLayer? = nil) {
        let command = ShapeCommand(
            geometry: .triangles(triangles),
            color: color,
            transform: pose.concatenating(transform),
            layer: layer ?? self.layer,
            clip: clip
        )
        scene.append(.shape(command))
    }

    // MARK: sprites & text

    public mutating func sprite(
        _ texture: TextureID, in destination: RenderRect,
        source: RenderRect? = nil, transform: Transform2D = .identity,
        tint: RenderColor = .white, opacity: Float = 1, layer: RenderLayer? = nil
    ) {
        scene.append(.sprite(SpriteCommand(
            texture: texture, destination: destination, source: source,
            transform: transform.concatenating(self.transform), tint: tint,
            layer: layer ?? self.layer, clip: clip, opacity: opacity
        )))
    }

    /// Records a static shader material without coupling scene authoring to a
    /// renderer or a specific shader implementation.
    public mutating func material(
        _ asset: ShaderAssetKey,
        texture: TextureID? = nil,
        in rect: RenderRect,
        parameters: ShaderParameterValues = ShaderParameterValues(),
        layer: RenderLayer? = nil
    ) {
        scene.append(.material(StaticShaderMaterialCommand(
            asset: asset,
            texture: texture,
            rect: rect,
            parameters: parameters,
            layer: layer ?? self.layer
        )))
    }

    public mutating func text(
        _ string: String, at origin: RenderPoint, scale: Float, color: RenderColor,
        centeredIn width: Float? = nil, centeredHeight: Float? = nil,
        layer: RenderLayer? = nil, font: FontRole = .ui,
        outline: Float = 0, outlineColor: RenderColor = RenderColor(0, 0, 0, 0)
    ) {
        scene.append(.text(TextCommand(
            string: string, origin: origin, scale: scale, color: color,
            outline: outline, outlineColor: outlineColor,
            centeredWidth: width, centeredHeight: centeredHeight, transform: transform,
            layer: layer ?? self.layer, clip: clip, font: font
        )))
    }

    /// Centre text on both axes inside a logical size. The origin is the
    /// top-left of the containing area; vertical centring uses the font's
    /// actual ink bounds when the compiler has atlas metrics available.
    public mutating func text(
        _ string: String, at origin: RenderPoint, scale: Float, color: RenderColor,
        centeredIn size: RenderSize,
        layer: RenderLayer? = nil, font: FontRole = .ui,
        outline: Float = 0, outlineColor: RenderColor = RenderColor(0, 0, 0, 0)
    ) {
        text(string, at: origin, scale: scale, color: color,
             centeredIn: size.width, centeredHeight: size.height,
             layer: layer, font: font, outline: outline, outlineColor: outlineColor)
    }

    /// Attach a renderer-neutral shader to a resolved region. This does not
    /// emit geometry; the active backend consumes the descriptor after scene
    /// compilation.
    public mutating func shader(_ shader: AnyShader, in rect: RenderRect) {
        scene.append(shaderRegion: ShaderRegion(rect: rect, shader: shader))
    }

    /// Insert an already-recorded view subtree as an isolated shader layer.
    /// Its commands retain their local paint order and are composited here,
    /// rather than being applied to the completed scene framebuffer.
    public mutating func shaderLayer(_ shader: AnyShader, in rect: RenderRect,
                                     commands: [DrawCommand]) {
        scene.append(shaderLayer: ShaderLayerCommand(rect: rect, shader: shader, commands: commands))
    }

    private var x3dStack: [X3DGraphAssembly] = []

    public mutating func beginX3D(in rect: RenderRect) {
        x3dStack.append(X3DGraphAssembly(rect: rect))
    }

    public mutating func emitX3D(_ op: X3DOp) {
        guard !x3dStack.isEmpty else { return }
        x3dStack[x3dStack.count - 1].apply(op)
    }

    public mutating func beginX3DView(in rect: RenderRect) {
        guard !x3dStack.isEmpty else { return }
        x3dStack[x3dStack.count - 1].viewRect = rect
        x3dStack[x3dStack.count - 1].outerScene = scene
        scene = Scene(background: RenderColor(0, 0, 0, 0), authoringCanvas: scene.authoringCanvas)
    }

    public mutating func endX3DView() {
        guard !x3dStack.isEmpty, let outer = x3dStack[x3dStack.count - 1].outerScene,
              let rect = x3dStack[x3dStack.count - 1].viewRect else { return }
        let commands = scene.commands
        scene = outer
        x3dStack[x3dStack.count - 1].outerScene = nil
        x3dStack[x3dStack.count - 1].viewRect = nil
        x3dStack[x3dStack.count - 1].pass?.items.append(.view(rect: rect, commands: commands))
    }

    public mutating func beginX3DPlane(size: RenderSize) {
        beginX3DView(in: RenderRect(x: 0, y: 0, width: size.width, height: size.height))
    }

    public mutating func endX3DPlane(camera: X3DCamera, model: X3DTransform) {
        guard !x3dStack.isEmpty, let outer = x3dStack[x3dStack.count - 1].outerScene,
              let rect = x3dStack[x3dStack.count - 1].viewRect else { return }
        let commands = scene.commands
        scene = outer
        x3dStack[x3dStack.count - 1].outerScene = nil
        x3dStack[x3dStack.count - 1].viewRect = nil
        x3dStack[x3dStack.count - 1].pass?.items.append(.plane(
            size: RenderSize(width: rect.width, height: rect.height),
            commands: commands, camera: camera, model: model
        ))
    }

    public mutating func endX3D() {
        guard let assembly = x3dStack.popLast() else { return }
        scene.append(.x3d(X3DCommand(rect: assembly.rect, graph: assembly.graph)))
    }

    /// Advance width. Uses the atlas metrics when `fonts` is supplied (so
    /// centring matches what the compiler will draw), else the vector font.
    public func textWidth(_ string: String, scale: Float, font: FontRole = .ui, fonts: FontBook? = nil) -> Float {
        if let atlas = fonts?[font] { return atlas.width(string, textScale: scale) }
        return TextMesher.width(string, scale: scale)
    }

    // MARK: core

    private mutating func shape(_ geometry: ShapeGeometry, color: RenderColor, layer: RenderLayer?) {
        scene.append(.shape(ShapeCommand(
            geometry: geometry, color: color, transform: transform,
            layer: layer ?? self.layer, clip: clip
        )))
    }
}
