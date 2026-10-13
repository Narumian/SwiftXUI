import Foundation
import XShader

/// A frame reduced to GPU-ready buffers and an ordered draw list. The WGPU
/// renderer walks `draws` and issues one call each; everything else here is
/// backend-neutral and unit-tested without a device.
public struct CompiledFrame: Sendable, Equatable {
    /// Interleaved NDC `x, y, r, g, b, a` for the shape pipeline.
    public var shapeVertices: [Float]
    /// Interleaved NDC `x, y, u, v, r, g, b, a` for the sprite pipeline.
    public var spriteVertices: [Float]
    /// Interleaved NDC `x, y, u, v, fill rgba, outline rgba, outline width,
    /// sdf range` for the SDF font pipeline. Kept separate from sprites so ordinary art
    /// retains its compact eight-float vertex format.
    public var fontVertices: [Float]
    public var draws: [CompiledDraw]
    /// Isolated view subtrees. A `.shaderLayer` draw references this table at
    /// the exact point it appeared in the authored command stream.
    public var shaderLayers: [CompiledShaderLayer]
    public var shaderRegions: [CompiledShaderRegion]
    /// Static shader material metadata resolved to framebuffer coordinates.
    /// Backends can consume this list when material pipelines are available.
    public var materials: [CompiledMaterialCommand]
    public var x3d: [CompiledX3D] = []
    public var background: RenderColor
    public var postIntensity: Float

    public init(
        shapeVertices: [Float] = [],
        spriteVertices: [Float] = [],
        fontVertices: [Float] = [],
        draws: [CompiledDraw] = [],
        shaderLayers: [CompiledShaderLayer] = [],
        shaderRegions: [CompiledShaderRegion] = [],
        materials: [CompiledMaterialCommand] = [],
        background: RenderColor = RenderColor(0.035, 0.018, 0.055, 1),
        postIntensity: Float = 1
    ) {
        self.shapeVertices = shapeVertices
        self.spriteVertices = spriteVertices
        self.fontVertices = fontVertices
        self.draws = draws
        self.shaderLayers = shaderLayers
        self.shaderRegions = shaderRegions
        self.materials = materials
        self.background = background
        self.postIntensity = postIntensity
    }
}

/// A logical shader region mapped into framebuffer pixels by the compiler.
public struct CompiledShaderRegion: Sendable, Equatable {
    public var rect: PixelRect
    public var shader: AnyShader

    public init(rect: PixelRect, shader: AnyShader) {
        self.rect = rect
        self.shader = shader
    }
}

/// A view subtree compiled independently so a `.layer` shader cannot sample
/// siblings, overlays, or the scene background behind it.
public struct CompiledShaderLayer: Sendable, Equatable {
    public var rect: PixelRect
    public var shader: AnyShader
    public var frame: CompiledFrame

    public init(rect: PixelRect, shader: AnyShader, frame: CompiledFrame) {
        self.rect = rect
        self.shader = shader
        self.frame = frame
    }
}

/// A compiled static material command. It contains no backend objects and is
/// safe to inspect, diff, or defer until a renderer supports material draws.
public struct CompiledMaterialCommand: Sendable, Equatable {
    public var asset: ShaderAssetKey
    public var texture: TextureID?
    public var rect: PixelRect
    public var parameters: ShaderParameterValues
    public var layer: RenderLayer

    public init(asset: ShaderAssetKey, texture: TextureID?, rect: PixelRect,
                parameters: ShaderParameterValues, layer: RenderLayer) {
        self.asset = asset
        self.texture = texture
        self.rect = rect
        self.parameters = parameters
        self.layer = layer
    }
}

public enum CompiledDraw: Sendable, Equatable {
    /// Vertex index range into `shapeVertices` (vertices, not floats).
    case shapes(range: Range<Int>, scissor: PixelRect?)
    /// Vertex index range into `spriteVertices`.
    case sprite(texture: TextureID, range: Range<Int>, scissor: PixelRect?)
    /// Vertex index range into `fontVertices`, sampled as a signed-distance atlas.
    case font(texture: TextureID, range: Range<Int>, scissor: PixelRect?)
    /// Index into `CompiledFrame.materials`; currently metadata-only for
    /// backends that do not yet execute static material pipelines.
    case material(index: Int)
    /// Composite the isolated subtree identified by `index` here.
    case shaderLayer(index: Int)
    /// Run and composite `CompiledFrame.x3d[index]` here.
    case x3d(index: Int)
}

/// An `X3DCommand` mapped to framebuffer pixels. `views` holds each embedded
/// view's frame in the order its `.view` items appear in the graph.
public struct CompiledX3D: Sendable, Equatable {
    /// The part of the command's rect that lies inside the framebuffer.
    public var rect: PixelRect
    /// The rect as laid out (x, y, width, height in framebuffer pixels), which may reach past the framebuffer.
    /// Shaders get this as their origin and resolution, so a drawing that overflows is cut off instead of squeezed to fit.
    public var exactRect: SIMD4<Float>?
    public var graph: X3DGraph
    public var views: [CompiledFrame]
    public var planes: [CompiledX3DPlane]

    public init(rect: PixelRect, exactRect: SIMD4<Float>? = nil, graph: X3DGraph, views: [CompiledFrame], planes: [CompiledX3DPlane] = []) {
        self.rect = rect
        self.exactRect = exactRect
        self.graph = graph
        self.views = views
        self.planes = planes
    }
}

/// A plane's view compiled aspect-fit into the full framebuffer; `uv` is the
/// `(minU, minV, maxU, maxV)` of the region it occupies there.
extension CompiledX3D {
    /// False when no pass would run or draw anything, so the renderer can skip the whole view without breaking the frame's pass.
    public var drawsAnything: Bool {
        graph.passes.contains { pass in
            switch pass {
            case .compute: return true
            case .render(let render): return !render.items.isEmpty
            }
        }
    }
}

public struct CompiledX3DPlane: Sendable, Equatable {
    public var frame: CompiledFrame
    public var uv: SIMD4<Float>

    public init(frame: CompiledFrame, uv: SIMD4<Float>) {
        self.frame = frame
        self.uv = uv
    }
}

/// Integer scissor in framebuffer pixels.
public struct PixelRect: Sendable, Equatable {
    public var x: UInt32, y: UInt32, width: UInt32, height: UInt32
    public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Maps authoring (canvas) points to framebuffer pixels, letterboxed and centred.
struct Letterbox {
    var scale: Float
    var offsetX: Float
    var offsetY: Float
    let fb: RenderSize

    init(canvas: RenderSize, framebuffer: RenderSize, fit: Bool) {
        fb = framebuffer
        if fit {
            scale = min(framebuffer.width / canvas.width, framebuffer.height / canvas.height)
        } else {
            scale = 1
        }
        if fit {
            offsetX = (framebuffer.width - canvas.width * scale) / 2
            offsetY = (framebuffer.height - canvas.height * scale) / 2
        } else {
            // Non-fit = stretch: use independent axis scales via ndc() below.
            offsetX = 0
            offsetY = 0
        }
        self.canvas = canvas
        self.fit = fit
    }
    let canvas: RenderSize
    let fit: Bool

    func ndc(_ x: Float, _ y: Float) -> (Float, Float) {
        if fit {
            let px = offsetX + x * scale
            let py = offsetY + y * scale
            return (px / fb.width * 2 - 1, 1 - py / fb.height * 2)
        } else {
            return (x / canvas.width * 2 - 1, 1 - y / canvas.height * 2)
        }
    }

    /// The rect in framebuffer pixels exactly as laid out, so it may start before the framebuffer or end past it.
    func exactPixels(_ rect: RenderRect) -> SIMD4<Float> {
        let x = fit ? offsetX + rect.x * scale : rect.x / canvas.width * fb.width
        let y = fit ? offsetY + rect.y * scale : rect.y / canvas.height * fb.height
        let w = fit ? rect.width * scale : rect.width / canvas.width * fb.width
        let h = fit ? rect.height * scale : rect.height / canvas.height * fb.height
        return SIMD4(x, y, w, h)
    }

    /// The part of the rect that lies inside the framebuffer.
    func visiblePixels(_ rect: RenderRect) -> PixelRect {
        let exact = exactPixels(rect)
        let x0 = min(max(exact.x, 0), fb.width), y0 = min(max(exact.y, 0), fb.height)
        let x1 = min(max(exact.x + exact.z, 0), fb.width), y1 = min(max(exact.y + exact.w, 0), fb.height)
        return PixelRect(x: UInt32(x0), y: UInt32(y0), width: UInt32(max(x1 - x0, 0)), height: UInt32(max(y1 - y0, 0)))
    }

    func pixels(_ rect: RenderRect) -> PixelRect {
        let x = fit ? offsetX + max(rect.x, 0) * scale : max(rect.x, 0) / canvas.width * fb.width
        let y = fit ? offsetY + max(rect.y, 0) * scale : max(rect.y, 0) / canvas.height * fb.height
        let w = fit ? rect.width * scale : rect.width / canvas.width * fb.width
        let h = fit ? rect.height * scale : rect.height / canvas.height * fb.height
        return PixelRect(x: UInt32(max(x, 0)), y: UInt32(max(y, 0)),
                         width: UInt32(max(w, 0)), height: UInt32(max(h, 0)))
    }
}

public enum SceneCompiler {
    /// Framebuffer pixels per logical unit `compile` will use — what text
    /// preparation needs to bake atlases at the size they will be drawn.
    public static func pixelScale(_ scene: Scene, canvas: RenderSize, framebuffer: RenderSize, fit: Bool = true) -> Float {
        Letterbox(canvas: scene.authoringCanvas ?? canvas, framebuffer: framebuffer, fit: fit).scale
    }

    /// `canvas` is the size the scene was authored against; `framebuffer` is the
    /// real pixel size. `fit` letterboxes (preserves aspect); `fit: false`
    /// stretches to fill. A scene that carries its own `authoringCanvas` (every
    /// `SceneBuilder`-made scene does) overrides `canvas` — so a scene authored
    /// straight at the device size fills it with an identity fit.
    public static func compile(
        _ scene: Scene,
        canvas: RenderSize,
        framebuffer: RenderSize,
        fit: Bool = true,
        fonts: FontBook? = nil
    ) -> CompiledFrame {
        var frame = CompiledFrame(background: scene.background, postIntensity: scene.postIntensity)
        let box = Letterbox(canvas: scene.authoringCanvas ?? canvas, framebuffer: framebuffer, fit: fit)
        frame.shaderRegions = scene.shaderRegions.map {
            CompiledShaderRegion(rect: box.pixels($0.rect), shader: $0.shader)
        }

        // Commands are already emitted in paint order. XUI walks a view
        // tree back-to-front, so preserving this sequence makes the authored
        // tree—not an imperative global layer bucket—the source of truth for
        // compositing. `RenderLayer` remains command metadata during the
        // migration, but no longer reorders draws here.
        let ordered = scene.commands

        var shapeRun: (start: Int, scissor: PixelRect?)?

        func flushShapes() {
            guard let run = shapeRun else { return }
            let end = frame.shapeVertices.count / 6
            if end > run.start {
                frame.draws.append(.shapes(range: run.start..<end, scissor: run.scissor))
            }
            shapeRun = nil
        }
        func clip(_ r: RenderRect?) -> PixelRect? { r.map(box.pixels) }
        func openShapeRun(_ scissor: PixelRect?) {
            if shapeRun == nil { shapeRun = (frame.shapeVertices.count / 6, scissor) }
            else if shapeRun!.scissor != scissor { flushShapes(); shapeRun = (frame.shapeVertices.count / 6, scissor) }
        }

        for command in ordered {
            switch command {
            case .shape(let shape):
                openShapeRun(clip(shape.clip))
                appendNDC(&frame.shapeVertices, ShapeMesher.mesh(shape), box)
            case .text(let text):
                if let atlas = fonts?.atlas(for: text.font, capPixels: 7 * text.scale * box.scale),
                   text.string.contains(where: { ch in
                       fonts?.atlas(for: text.font, capPixels: 7 * text.scale * box.scale, character: ch)?.glyphs[ch] != nil
                   }) {
                    flushShapes()
                    let ranges = appendGlyphs(
                        &frame.fontVertices, text, atlas, box,
                        atlasFor: { ch in fonts?.atlas(for: text.font, capPixels: 7 * text.scale * box.scale, character: ch) }
                    )
                    for (texture, range) in ranges where !range.isEmpty {
                        frame.draws.append(.font(texture: texture, range: range, scissor: clip(text.clip)))
                    }
                } else {
                    openShapeRun(clip(text.clip))
                    appendNDC(&frame.shapeVertices, TextMesher.mesh(text), box)
                }
            case .sprite(let sprite):
                flushShapes()
                let start = frame.spriteVertices.count / 8
                appendSprite(&frame.spriteVertices, sprite, box)
                let end = frame.spriteVertices.count / 8
                frame.draws.append(.sprite(texture: sprite.texture, range: start..<end, scissor: clip(sprite.clip)))
            case .material(let material):
                // Preserve material position in the ordered stream while
                // retaining metadata separately for future backend support.
                flushShapes()
                let index = frame.materials.count
                frame.materials.append(CompiledMaterialCommand(
                    asset: material.asset,
                    texture: material.texture,
                    rect: box.pixels(material.rect),
                    parameters: material.parameters,
                    layer: material.layer
                ))
                frame.draws.append(.material(index: index))
            case .shaderLayer(let layer):
                flushShapes()
                let nested = Scene(
                    background: RenderColor(0, 0, 0, 0), commands: layer.commands,
                    authoringCanvas: scene.authoringCanvas
                )
                let child = compile(nested, canvas: canvas, framebuffer: framebuffer, fit: fit, fonts: fonts)
                let index = frame.shaderLayers.count
                frame.shaderLayers.append(CompiledShaderLayer(
                    rect: box.pixels(layer.rect), shader: layer.shader, frame: child
                ))
                frame.draws.append(.shaderLayer(index: index))
            case .x3d(let x3d):
                flushShapes()
                var views: [CompiledFrame] = []
                var planes: [CompiledX3DPlane] = []
                for case .render(let pass) in x3d.graph.passes {
                    for item in pass.items {
                        switch item {
                        case .view(_, let commands):
                            let nested = Scene(
                                background: RenderColor(0, 0, 0, 0), commands: commands,
                                authoringCanvas: scene.authoringCanvas
                            )
                            views.append(compile(nested, canvas: canvas, framebuffer: framebuffer, fit: fit, fonts: fonts))
                        case .plane(let size, let commands, _, _):
                            guard size.width > 0, size.height > 0 else { continue }
                            let nested = Scene(background: RenderColor(0, 0, 0, 0), commands: commands,
                                               authoringCanvas: size)
                            let planeBox = Letterbox(canvas: size, framebuffer: framebuffer, fit: true)
                            let uv = SIMD4(
                                planeBox.offsetX / framebuffer.width, planeBox.offsetY / framebuffer.height,
                                (planeBox.offsetX + size.width * planeBox.scale) / framebuffer.width,
                                (planeBox.offsetY + size.height * planeBox.scale) / framebuffer.height
                            )
                            planes.append(CompiledX3DPlane(
                                frame: compile(nested, canvas: size, framebuffer: framebuffer, fit: true, fonts: fonts),
                                uv: uv
                            ))
                        case .draw, .blit:
                            continue
                        }
                    }
                }
                let index = frame.x3d.count
                frame.x3d.append(CompiledX3D(rect: box.visiblePixels(x3d.rect), exactRect: box.exactPixels(x3d.rect), graph: x3d.graph, views: views, planes: planes))
                frame.draws.append(.x3d(index: index))
            }
        }
        flushShapes()
        return frame
    }

    private static func appendNDC(_ dst: inout [Float], _ logical: [Float], _ box: Letterbox) {
        var i = 0
        while i + 5 < logical.count {
            let (x, y) = box.ndc(logical[i], logical[i + 1])
            dst.append(x); dst.append(y)
            dst.append(logical[i + 2]); dst.append(logical[i + 3])
            dst.append(logical[i + 4]); dst.append(logical[i + 5])
            i += 6
        }
    }

    /// Lay a `TextCommand` out as textured quads. A logical font size may be
    /// split across several texture pages, so the returned ranges are grouped
    /// into contiguous page runs while the pen still advances across the full
    /// string.
    private static func appendGlyphs(
        _ dst: inout [Float], _ text: TextCommand, _ atlas: FontAtlas, _ box: Letterbox,
        atlasFor: (Character) -> FontAtlas?
    ) -> [(TextureID, Range<Int>)] {
        // A native-size atlas is drawn 1:1 with glyph quads on whole
        // framebuffer pixels (no resampling, so stems keep the weight they were
        // baked with). That needs an unrotated, unscaled placement and an atlas
        // within a few percent of the requested size, because the 1:1 quads
        // bypass `drawScale` and layout measured the string at the requested size.
        let capPixels = 7 * text.scale * box.scale
        let chars = Array(text.string)
        let glyphAtlases = text.string.map { atlasFor($0) ?? atlas }
        // Each glyph is scaled by the page it is taken from. A character that is only baked on
        // another size's page still comes out at the requested size instead of that page's own.
        func isNative(_ page: FontAtlas) -> Bool {
            page.native && box.fit && text.transform == .identity
                && abs(page.capHeight - capPixels) <= 0.04 * capPixels
        }
        let scales = glyphAtlases.map { page in isNative(page) ? 1 / box.scale : page.drawScale(text.scale) }
        let natives = glyphAtlases.map(isNative)
        func snapX(_ x: Float, _ native: Bool) -> Float { native ? ((box.offsetX + x * box.scale).rounded() - box.offsetX) / box.scale : x }
        func snapY(_ y: Float, _ native: Bool) -> Float { native ? ((box.offsetY + y * box.scale).rounded() - box.offsetY) / box.scale : y }
        func glyph(_ index: Int) -> GlyphBox? {
            glyphAtlases[index].glyphs[chars[index]]
        }
        var lineWidth: Float = 0
        for i in chars.indices {
            let page = glyphAtlases[i]
            lineWidth += (page.glyphs[chars[i]]?.advance ?? page.glyphs[" "]?.advance ?? page.pixelSize * 0.5) * scales[i]
        }
        var penX = text.centeredWidth.map { text.origin.x + ($0 - lineWidth) * 0.5 } ?? text.origin.x
        // Always ink-centred: the baseline comes from this string's measured
        // ink bounds inside the box starting at origin.y. Without an explicit
        // centeredHeight the box is one atlas line, matching measureText.
        var inkTop: Float?
        var inkBottom: Float?
        for i in chars.indices {
            guard let g = glyph(i), g.w > 0, g.h > 0 else { continue }
            let top = g.top * scales[i]
            let bottom = (g.top - g.h) * scales[i]
            inkTop = max(inkTop ?? top, top)
            inkBottom = min(inkBottom ?? bottom, bottom)
        }
        let lineScale = isNative(atlas) ? 1 / box.scale : atlas.drawScale(text.scale)
        let boxHeight = text.centeredHeight ?? atlas.lineHeight * lineScale
        let inkCenterAboveBaseline = ((inkTop ?? 0) + (inkBottom ?? 0)) * 0.5
        let baselineY = text.origin.y + boxHeight * 0.5 + inkCenterAboveBaseline
        let a = text.color.alpha
        let tint = (text.color.red * a, text.color.green * a, text.color.blue * a, a)
        let outlineAlpha = text.outlineColor.alpha
        let outlineTint = (text.outlineColor.red * outlineAlpha, text.outlineColor.green * outlineAlpha,
                           text.outlineColor.blue * outlineAlpha, outlineAlpha)
        // Keep a deliberate HUD stroke legible without letting it become a
        // black slab: cap it at 20% of cap height, with a one-framebuffer-pixel
        // floor. `fwidth(distance)` then carries this through responsive
        // layout, device scale, and transforms.
        let requestedOutline = text.outline * box.scale
        let maximumOutline = 7 * text.scale * 0.20 * box.scale
        let outline = text.outlineColor.alpha > 0 && text.outline > 0
            ? max(1, min(requestedOutline, maximumOutline))
            : 0
        let order = [0, 1, 2, 0, 2, 3]

        var ranges: [(TextureID, Range<Int>)] = []
        var activeTexture: TextureID?
        var activeStart = dst.count / 14
        func closeRun() {
            guard let texture = activeTexture else { return }
            let end = dst.count / 14
            if end > activeStart { ranges.append((texture, activeStart..<end)) }
        }

        for i in chars.indices {
            let ch = chars[i]
            let page = glyphAtlases[i]
            if activeTexture != page.texture {
                closeRun()
                activeTexture = page.texture
                activeStart = dst.count / 14
            }
            let s = scales[i]
            guard let g = page.glyphs[ch] else {
                penX += (page.glyphs[" "]?.advance ?? page.pixelSize * 0.5) * s
                continue
            }
            if g.w > 0, g.h > 0 {
                let x0 = snapX(penX + g.left * s, natives[i])
                let y0 = snapY(baselineY - g.top * s, natives[i])
                let x1 = x0 + g.w * s
                let y1 = y0 + g.h * s
                let corners = [RenderPoint(x: x0, y: y0), RenderPoint(x: x1, y: y0),
                               RenderPoint(x: x1, y: y1), RenderPoint(x: x0, y: y1)].map(text.transform.apply)
                let u0 = g.x / page.atlasWidth, v0 = g.y / page.atlasHeight
                let u1 = (g.x + g.w) / page.atlasWidth, v1 = (g.y + g.h) / page.atlasHeight
                let uv = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
                for idx in order {
                    let (nx, ny) = box.ndc(corners[idx].x, corners[idx].y)
                    dst.append(nx); dst.append(ny)
                    dst.append(uv[idx].0); dst.append(uv[idx].1)
                    dst.append(tint.0); dst.append(tint.1); dst.append(tint.2); dst.append(tint.3)
                    dst.append(outlineTint.0); dst.append(outlineTint.1)
                    dst.append(outlineTint.2); dst.append(outlineTint.3)
                    dst.append(outline)
                    dst.append(page.sdfRange)
                }
            }
            penX += g.advance * s
        }
        closeRun()
        return ranges
    }

    private static func appendSprite(_ dst: inout [Float], _ sprite: SpriteCommand, _ box: Letterbox) {
        let d = sprite.destination
        let corners = [
            RenderPoint(x: d.x, y: d.y),
            RenderPoint(x: d.x + d.width, y: d.y),
            RenderPoint(x: d.x + d.width, y: d.y + d.height),
            RenderPoint(x: d.x, y: d.y + d.height),
        ].map(sprite.transform.apply)

        let uv = [(Float(0), Float(0)), (1, 0), (1, 1), (0, 1)]
        let a = sprite.tint.alpha * sprite.opacity
        let tint = (sprite.tint.red * a, sprite.tint.green * a, sprite.tint.blue * a, a)
        let order = [0, 1, 2, 0, 2, 3]
        for idx in order {
            let (x, y) = box.ndc(corners[idx].x, corners[idx].y)
            dst.append(x); dst.append(y)
            dst.append(uv[idx].0); dst.append(uv[idx].1)
            dst.append(tint.0); dst.append(tint.1); dst.append(tint.2); dst.append(tint.3)
        }
    }
}
