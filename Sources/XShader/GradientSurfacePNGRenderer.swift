import Foundation

#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// CPU reference renderer for the built-in GradientSurface asset.
///
/// This intentionally lives in XShader (rather than a renderer target) so
/// callers can produce a stable visual reference without a GPU drawable.
public enum GradientSurfacePNGRenderer {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidDimensions
        case invalidDescriptor
        case missingParameter(String)
        case unavailable
        case encodingFailed
    }

    /// Encodes GradientSurface to an opaque, deterministic PNG.
    public static func renderPNG(
        descriptor: ShaderAssetDescriptor = GradientSurfaceAsset.descriptor,
        values: ShaderParameterValues? = nil,
        width: Int,
        height: Int
    ) throws -> Data {
        guard width > 0, height > 0 else { throw Error.invalidDimensions }
        guard descriptor.key == GradientSurfaceAsset.key else { throw Error.invalidDescriptor }
        let parameterValues = values ?? ShaderParameterValues(descriptor: descriptor)
        func float(_ id: String) throws -> Float {
            guard case .float(let value) = parameterValues.values[id] else { throw Error.missingParameter(id) }
            return value
        }
        func color(_ id: String) throws -> ShaderColor {
            guard case .color(let value) = parameterValues.values[id] else { throw Error.missingParameter(id) }
            return value
        }

        let gradientMix = try float("gradient_mix")
        let saturation = try float("saturation")
        let contrast = try float("contrast")
        let radialAmount = try float("radial_amount")
        let colorA = try color("color_a")
        let colorB = try color("color_b")
        var rgba = Data(count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let aspect = Float(width) / Float(height)
            for y in 0..<height {
                for x in 0..<width {
                    // Metal/WGSL rasterization evaluates this at pixel centers.
                    let uvx = (Float(x) + 0.5) / Float(width)
                    let uvy = (Float(y) + 0.5) / Float(height)
                    // Match gradient_linear_t(uv, (0, 0), (1, 1)) in WGSL.
                    let linearT = clamp((uvx + uvy) * 0.5, 0, 1)
                    let dx = (uvx - 0.5) * aspect
                    let dy = uvy - 0.5
                    let radialT = clamp(sqrt(dx * dx + dy * dy) / 0.72, 0, 1)
                    let mixedT = mix(linearT, radialT, clamp(radialAmount, 0, 1))
                    let t = mix(mixedT, linearT, clamp(gradientMix, 0, 1))
                    var r = mix(colorA.red, colorB.red, t)
                    var g = mix(colorA.green, colorB.green, t)
                    var b = mix(colorA.blue, colorB.blue, t)
                    let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let sat = max(saturation, 0)
                    r = luminance + (r - luminance) * sat
                    g = luminance + (g - luminance) * sat
                    b = luminance + (b - luminance) * sat
                    let con = max(contrast, 0)
                    r = (r - 0.5) * con + 0.5
                    g = (g - 0.5) * con + 0.5
                    b = (b - 0.5) * con + 0.5
                    let offset = (y * width + x) * 4
                    bytes[offset] = toByte(sRGB(r))
                    bytes[offset + 1] = toByte(sRGB(g))
                    bytes[offset + 2] = toByte(sRGB(b))
                    bytes[offset + 3] = 255
                }
            }
        }
        return try encodePNG(rgba: rgba, width: width, height: height)
    }

    /// Convenience API for callers that do not need to construct parameter values.
    public static func renderPNG(
        width: Int, height: Int,
        gradientMix: Float = 0.5, saturation: Float = 1, contrast: Float = 1,
        radialAmount: Float = 0,
        colorA: ShaderColor = ShaderColor(red: 0.01938236, green: 0.13563333, blue: 1),
        colorB: ShaderColor = ShaderColor(red: 1, green: 0.45078578, blue: 0.06301002),
        descriptor: ShaderAssetDescriptor = GradientSurfaceAsset.descriptor
    ) throws -> Data {
        var values = ShaderParameterValues(descriptor: descriptor)
        try values.set(.float(gradientMix), for: "gradient_mix", descriptor: descriptor)
        try values.set(.float(saturation), for: "saturation", descriptor: descriptor)
        try values.set(.float(contrast), for: "contrast", descriptor: descriptor)
        try values.set(.float(radialAmount), for: "radial_amount", descriptor: descriptor)
        try values.set(.color(colorA), for: "color_a", descriptor: descriptor)
        try values.set(.color(colorB), for: "color_b", descriptor: descriptor)
        return try renderPNG(descriptor: descriptor, values: values, width: width, height: height)
    }

    private static func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float { min(max(value, low), high) }
    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    private static func sRGB(_ value: Float) -> Float {
        let safe = max(value, 0)
        return safe <= 0.0031308 ? safe * 12.92 : 1.055 * pow(safe, 1 / 2.4) - 0.055
    }
    private static func toByte(_ value: Float) -> UInt8 { UInt8(clamp(value, 0, 1) * 255 + 0.5) }

    private static func encodePNG(rgba: Data, width: Int, height: Int) throws -> Data {
        #if canImport(CoreGraphics) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { throw Error.encodingFailed }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw Error.encodingFailed }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGInterlaceType: 0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Error.encodingFailed }
        return output as Data
        #else
        throw Error.unavailable
        #endif
    }
}
