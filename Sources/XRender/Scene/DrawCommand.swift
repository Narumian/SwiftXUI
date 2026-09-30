import Foundation
import XShader

/// Back-to-front paint order. Submission order is preserved within a layer.
public enum RenderLayer: Int, Sendable, Equatable, CaseIterable, Comparable {
    case background   // full-screen environment
    case world        // map geometry, machine body
    case actors       // characters, enemies
    case foreground   // props in front of actors
    case vfx          // glows, bursts, particles
    case ui           // panels, buttons, bars
    case overlay      // transitions, stingers, modal dim

    public static func < (lhs: RenderLayer, rhs: RenderLayer) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Opaque handle for a texture registered with the renderer's `TextureStore`.
public struct TextureID: Sendable, Equatable, Hashable {
    public var rawValue: UInt32
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

/// Vector geometry, in logical (point) space. Tessellated to triangles by
/// `ShapeMesher`; the command's `transform` is applied to the generated points.
public enum ShapeGeometry: Sendable, Equatable {
    case rect(RenderRect, corner: Float)
    case circle(center: RenderPoint, radius: Float)
    case ellipse(center: RenderPoint, radiusX: Float, radiusY: Float)
    /// Open or closed stroked polyline.
    case stroke(points: [RenderPoint], width: Float, closed: Bool)
    /// Filled simple polygon (may be concave; triangulated by ear clipping).
    case polygon(points: [RenderPoint])
    /// Already-tessellated interleaved x/y pairs (e.g. a `PartedMesh` part).
    case triangles([Float])
    case verticalGradient(RenderRect, top: RenderColor, bottom: RenderColor)
}

public struct ShapeCommand: Sendable, Equatable {
    public var geometry: ShapeGeometry
    public var color: RenderColor
    public var transform: Transform2D
    public var layer: RenderLayer
    public var clip: RenderRect?
    public var opacity: Float

    public init(
        geometry: ShapeGeometry,
        color: RenderColor,
        transform: Transform2D = .identity,
        layer: RenderLayer = .ui,
        clip: RenderRect? = nil,
        opacity: Float = 1
    ) {
        self.geometry = geometry
        self.color = color
        self.transform = transform
        self.layer = layer
        self.clip = clip
        self.opacity = opacity
    }
}

public struct SpriteCommand: Sendable, Equatable {
    public var texture: TextureID
    /// Sub-rectangle of the texture in pixels; `nil` uses the whole texture.
    public var source: RenderRect?
    /// Destination in logical space, before `transform`.
    public var destination: RenderRect
    public var transform: Transform2D
    /// Multiplied with the sampled texel. Default white = unchanged.
    public var tint: RenderColor
    public var layer: RenderLayer
    public var clip: RenderRect?
    public var opacity: Float

    public init(
        texture: TextureID,
        destination: RenderRect,
        source: RenderRect? = nil,
        transform: Transform2D = .identity,
        tint: RenderColor = .white,
        layer: RenderLayer = .background,
        clip: RenderRect? = nil,
        opacity: Float = 1
    ) {
        self.texture = texture
        self.destination = destination
        self.source = source
        self.transform = transform
        self.tint = tint
        self.layer = layer
        self.clip = clip
        self.opacity = opacity
    }
}

/// A renderer-neutral material invocation for a static shader asset.
///
/// The command intentionally carries an asset key rather than source code or
/// a GPU handle. Backends may resolve `texture` and `parameters` when they add
/// support for material execution; scene recording and inspection remain
/// backend-independent in the meantime.
public struct StaticShaderMaterialCommand: Sendable, Equatable {
    public var asset: ShaderAssetKey
    public var texture: TextureID?
    /// The already-resolved destination in logical scene coordinates.
    public var rect: RenderRect
    public var parameters: ShaderParameterValues
    public var layer: RenderLayer

    public init(
        asset: ShaderAssetKey,
        texture: TextureID? = nil,
        rect: RenderRect,
        parameters: ShaderParameterValues = ShaderParameterValues(),
        layer: RenderLayer = .ui
    ) {
        self.asset = asset
        self.texture = texture
        self.rect = rect
        self.parameters = parameters
        self.layer = layer
    }
}

/// Typeface role (README Typography). Maps to a baked glyph atlas at runtime;
/// falls back to the monoline `VectorFont` when no atlas is registered.
public enum FontRole: String, Sendable, Equatable, CaseIterable, Codable {
    case ui        // Zen Maru Gothic — Japanese UI, labels, descriptions
    case numeric   // Fredoka — numbers, prices, buttons, short Latin
    case display   // Dela Gothic One — large-impact words
    case impact    // Impact (OS font) — the aura numeral/percent badges only
}

public struct TextCommand: Sendable, Equatable {
    public var string: String
    public var origin: RenderPoint
    public var scale: Float
    public var color: RenderColor
    /// Width of the glyph outline in logical canvas units. Atlas-backed text
    /// turns this into a single SDF draw; the vector fallback ignores it.
    public var outline: Float
    public var outlineColor: RenderColor
    public var centeredWidth: Float?
    /// When set, the baseline is derived from this string's *actual measured
    /// ink bounds* (via the font atlas, or `TextMesher`'s known fixed glyph
    /// span) so its true vertical center lands at `origin.y + centeredHeight
    /// / 2` — instead of the fixed "baseline sits one nominal cap-height
    /// below origin.y" rule, which only happens to look centered for the one
    /// font/script mix it was eyeballed against. `origin.y` is this box's top
    /// edge, mirroring how `centeredWidth` treats `origin.x` as the left edge.
    public var centeredHeight: Float?
    public var transform: Transform2D
    public var layer: RenderLayer
    public var clip: RenderRect?
    public var font: FontRole

    public init(
        string: String,
        origin: RenderPoint,
        scale: Float,
        color: RenderColor,
        outline: Float = 0,
        outlineColor: RenderColor = RenderColor(0, 0, 0, 0),
        centeredWidth: Float? = nil,
        centeredHeight: Float? = nil,
        transform: Transform2D = .identity,
        layer: RenderLayer = .ui,
        clip: RenderRect? = nil,
        font: FontRole = .ui
    ) {
        self.string = string
        self.origin = origin
        self.scale = scale
        self.color = color
        self.outline = max(0, outline)
        self.outlineColor = outlineColor
        self.centeredWidth = centeredWidth
        self.centeredHeight = centeredHeight
        self.transform = transform
        self.layer = layer
        self.clip = clip
        self.font = font
    }
}

/// An isolated view subtree. The child commands are first rasterised into a
/// transparent layer and then the shader is evaluated before that layer is
/// composited back at this exact point in paint order.
public struct ShaderLayerCommand: Sendable, Equatable {
    public var rect: RenderRect
    public var shader: AnyShader
    public var commands: [DrawCommand]

    public init(rect: RenderRect, shader: AnyShader, commands: [DrawCommand]) {
        self.rect = rect
        self.shader = shader
        self.commands = commands
    }
}

public indirect enum DrawCommand: Sendable, Equatable {
    case shape(ShapeCommand)
    case sprite(SpriteCommand)
    case material(StaticShaderMaterialCommand)
    case text(TextCommand)
    case shaderLayer(ShaderLayerCommand)

    public var layer: RenderLayer {
        switch self {
        case .shape(let c): return c.layer
        case .sprite(let c): return c.layer
        case .material(let c): return c.layer
        case .text(let c): return c.layer
        // A layer has no intrinsic render layer: its placement in this ordered
        // command stream is its z-order.
        case .shaderLayer: return .ui
        }
    }
}

/// A full frame's worth of commands plus the clear colour. Renderer-neutral.
public struct Scene: Sendable, Equatable {
    public private(set) var commands: [DrawCommand]
    public private(set) var shaderRegions: [ShaderRegion]
    public var background: RenderColor
    /// Per-frame multiplier for the renderer's post pass (dither/VHS). 1 = the
    /// renderer's own `postIntensity`; bump it briefly on impacts.
    public var postIntensity: Float
    /// The logical size this scene's coordinates were authored against. When set,
    /// `SceneCompiler` / exporters letterbox-fit *this* size to the framebuffer
    /// instead of a caller-supplied constant — so a scene authored straight at
    /// the device size fills it with no letterbox. `nil` ⇒ caller decides.
    public var authoringCanvas: RenderSize?

    public init(
        background: RenderColor = RenderColor(0.035, 0.018, 0.055, 1),
        commands: [DrawCommand] = [],
        shaderRegions: [ShaderRegion] = [],
        postIntensity: Float = 1,
        authoringCanvas: RenderSize? = nil
    ) {
        self.background = background
        self.commands = commands
        self.shaderRegions = shaderRegions
        self.postIntensity = postIntensity
        self.authoringCanvas = authoringCanvas
    }

    public mutating func append(_ command: DrawCommand) {
        commands.append(command)
    }

    public mutating func append(contentsOf more: [DrawCommand]) {
        commands.append(contentsOf: more)
    }

    public mutating func append(shaderRegion: ShaderRegion) {
        shaderRegions.append(shaderRegion)
    }

    public mutating func append(shaderLayer: ShaderLayerCommand) {
        commands.append(.shaderLayer(shaderLayer))
    }
}
