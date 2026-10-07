import Foundation

/// Stable identity used by a renderer to select a compiled shader pipeline.
/// The core deliberately stores no WGSL, MSL, or GPU handles.
public struct ShaderKey: RawRepresentable, Hashable, Sendable, Codable,
                         ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

/// Where a shader is evaluated in the render graph.
public enum ShaderScope: String, Sendable, Equatable, Codable {
    /// Runs while drawing a primitive (shape, sprite, or text).
    case material
    /// Runs over a view subtree rasterised to a temporary layer.
    case layer
    /// Runs over the completed frame.
    case post
}

/// A small, deterministic uniform payload. Backends choose how to upload it;
/// the authoring side never needs to know about bind groups or buffers.
public struct ShaderUniforms: Sendable, Equatable, Codable {
    public private(set) var values: [Float]

    public init(values: [Float] = []) {
        self.values = values
    }

    public mutating func write(_ value: Float) {
        values.append(value)
    }

    public mutating func write(_ value: SIMD2<Float>) {
        values.append(value.x)
        values.append(value.y)
    }

    public mutating func write(_ value: SIMD3<Float>) {
        values.append(value.x)
        values.append(value.y)
        values.append(value.z)
    }

    public mutating func write(_ value: SIMD4<Float>) {
        values.append(value.x)
        values.append(value.y)
        values.append(value.z)
        values.append(value.w)
    }
}

/// Renderer-neutral shader description. Conformers describe their identity,
/// scope, and uniform values; a backend supplies the actual shader source.
public protocol Shader: Sendable {
    static var key: ShaderKey { get }
    static var scope: ShaderScope { get }
    func encode(into uniforms: inout ShaderUniforms)
}

/// Type-erased form stored by the layout/render runtime. Keeping this value
/// Equatable makes it suitable for command inspection and future frame diffs.
public struct AnyShader: Sendable, Equatable, Codable {
    public let key: ShaderKey
    public let scope: ShaderScope
    public let uniforms: ShaderUniforms

    public init<S: Shader>(_ shader: S) {
        self.key = S.key
        self.scope = S.scope
        var uniforms = ShaderUniforms()
        shader.encode(into: &uniforms)
        self.uniforms = uniforms
    }
}

public extension Shader {
    func erased() -> AnyShader { AnyShader(self) }
}

/// Small built-in effects shared by the sample/library backends. They are
/// intentionally data-only; the WGSL/MSL implementation is selected by the
/// renderer from the stable key.
public enum ShaderLibrary {
    public static let cellGlowKey: ShaderKey = "swiftx.cellGlow"
    public static let cellShineKey: ShaderKey = "swiftx.cellShine"
    public static let hitFlashKey: ShaderKey = "swiftx.hitFlash"
    public static let glassKey: ShaderKey = "swiftx.glass"
    public static let vhsKey: ShaderKey = "swiftx.vhs"
    public static let foilKey: ShaderKey = "swiftx.foil"
    public static let lenticularKey: ShaderKey = "swiftx.lenticular"
    public static let warpKey: ShaderKey = "swiftx.warp"

    public static func vhs(intensity: Float = 1) -> VHSShader {
        VHSShader(intensity: intensity)
    }

    public static func foil(phase: Float = 0, density: Float = 2, saturation: Float = 0.8, strength: Float = 1) -> FoilShader {
        FoilShader(phase: phase, density: density, saturation: saturation, strength: strength)
    }

    public static func lenticular(tilt: Float = 0, stripes: Float = 14, depth: Float = 1, strength: Float = 1) -> LenticularShader {
        LenticularShader(tilt: tilt, stripes: stripes, depth: depth, strength: strength)
    }

    public static func warp(phase: Float = 0, frequency: Float = 9, strength: Float = 1, amplitude: Float = 1) -> WarpShader {
        WarpShader(phase: phase, frequency: frequency, strength: strength, amplitude: amplitude)
    }

    public static func cellGlow(color: SIMD3<Float>, intensity: Float = 1) -> CellGlowShader {
        CellGlowShader(color: color, intensity: intensity)
    }

    public static func cellShine(color: SIMD3<Float>, progress: Float = 0) -> CellShineShader {
        CellShineShader(color: color, progress: progress)
    }

    public static func hitFlash(amount: Float = 1) -> HitFlashShader {
        HitFlashShader(amount: amount)
    }

    public static func glass(
        tint: SIMD3<Float> = SIMD3(0.70, 0.88, 1.0),
        intensity: Float = 0.28
    ) -> GlassShader {
        GlassShader(tint: tint, intensity: intensity)
    }
}

public struct CellGlowShader: Shader {
    public static let key = ShaderLibrary.cellGlowKey
    public static let scope: ShaderScope = .layer

    public var color: SIMD3<Float>
    public var intensity: Float

    public init(color: SIMD3<Float>, intensity: Float = 1) {
        self.color = color
        self.intensity = intensity
    }

    public func encode(into uniforms: inout ShaderUniforms) {
        uniforms.write(color)
        uniforms.write(intensity)
    }
}

public struct CellShineShader: Shader {
    public static let key = ShaderLibrary.cellShineKey
    public static let scope: ShaderScope = .layer

    public var color: SIMD3<Float>
    public var progress: Float

    public init(color: SIMD3<Float>, progress: Float = 0) {
        self.color = color
        self.progress = progress
    }

    public func encode(into uniforms: inout ShaderUniforms) {
        uniforms.write(color)
        uniforms.write(progress)
    }
}

public struct HitFlashShader: Shader {
    public static let key = ShaderLibrary.hitFlashKey
    public static let scope: ShaderScope = .layer

    public var amount: Float

    public init(amount: Float = 1) {
        self.amount = amount
    }

    public func encode(into uniforms: inout ShaderUniforms) {
        uniforms.write(amount)
    }
}

/// A restrained glass pass for a complete view subtree. The backend adds a
/// small animated refraction, cool tint, and edge rim without changing layout.
public struct GlassShader: Shader {
    public static let key = ShaderLibrary.glassKey
    public static let scope: ShaderScope = .layer

    public var tint: SIMD3<Float>
    public var intensity: Float

    public init(tint: SIMD3<Float> = SIMD3(0.70, 0.88, 1.0), intensity: Float = 0.28) {
        self.tint = tint
        self.intensity = intensity
    }

    public func encode(into uniforms: inout ShaderUniforms) {
        uniforms.write(tint)
        uniforms.write(intensity)
    }
}

/// Understated VHS for a view subtree: edge chromatic aberration, faint
/// scanlines, and fine grain. `intensity` scales all three.
public struct VHSShader: Shader {
    public static let key = ShaderLibrary.vhsKey
    public static let scope: ShaderScope = .layer

    public var intensity: Float

    public init(intensity: Float = 1) {
        self.intensity = intensity
    }

    public func encode(into uniforms: inout ShaderUniforms) {
        uniforms.write(SIMD3<Float>(0, 0, 0))
        uniforms.write(intensity)
    }
}

public struct FoilShader: Shader {
    public static let key = ShaderLibrary.foilKey
    public static let scope: ShaderScope = .layer

    public var phase: Float
    public var density: Float
    public var saturation: Float
    public var strength: Float

    public init(phase: Float = 0, density: Float = 2, saturation: Float = 0.8, strength: Float = 1) {
        self.phase = phase
        self.density = density
        self.saturation = saturation
        self.strength = strength
    }

    public func encode(into uniforms: inout ShaderUniforms) {
        uniforms.write(SIMD4<Float>(phase, density, saturation, strength))
    }
}

public struct LenticularShader: Shader {
    public static let key = ShaderLibrary.lenticularKey
    public static let scope: ShaderScope = .layer

    public var tilt: Float
    public var stripes: Float
    public var depth: Float
    public var strength: Float

    public init(tilt: Float = 0, stripes: Float = 14, depth: Float = 1, strength: Float = 1) {
        self.tilt = tilt
        self.stripes = stripes
        self.depth = depth
        self.strength = strength
    }

    public func encode(into uniforms: inout ShaderUniforms) {
        uniforms.write(SIMD4<Float>(tilt, stripes, depth, strength))
    }
}

public struct WarpShader: Shader {
    public static let key = ShaderLibrary.warpKey
    public static let scope: ShaderScope = .layer

    public var phase: Float
    public var frequency: Float
    public var strength: Float
    public var amplitude: Float

    public init(phase: Float = 0, frequency: Float = 9, strength: Float = 1, amplitude: Float = 1) {
        self.phase = phase
        self.frequency = frequency
        self.strength = strength
        self.amplitude = amplitude
    }

    public func encode(into uniforms: inout ShaderUniforms) {
        uniforms.write(SIMD4<Float>(phase, frequency, amplitude, strength))
    }
}
