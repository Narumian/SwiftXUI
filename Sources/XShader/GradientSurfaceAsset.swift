import Foundation

/// The first static asset in the shader library.
public enum GradientSurfaceAsset {
    public static let key = ShaderAssetKey("shader.gradient_surface")!
    public static let rootFile = "assets/gradient_surface.wgsl"
    public static let foundationFiles = [
        "foundation/color.wgsl", "foundation/uv.wgsl", "foundation/gradient.wgsl"
    ]

    public static var descriptor: ShaderAssetDescriptor {
        ShaderAssetDescriptor(key: key, rootFile: rootFile, parameters: [
            .init(id: "gradient_mix", displayName: "Gradient Mix", type: .float, defaultValue: .float(0.5), range: 0...1, gpuSlot: .slot0X),
            .init(id: "saturation", displayName: "Saturation", type: .float, defaultValue: .float(1), range: 0...2, gpuSlot: .slot0Y),
            .init(id: "contrast", displayName: "Contrast", type: .float, defaultValue: .float(1), range: 0...2, gpuSlot: .slot0Z),
            .init(id: "radial_amount", displayName: "Radial Amount", type: .float, defaultValue: .float(0), range: 0...1, gpuSlot: .slot0W),
            .init(id: "color_a", displayName: "Color A", type: .color, defaultValue: .color(sRGB(red: 0x26, green: 0x67, blue: 0xFF)), gpuSlot: .slot1RGB),
            .init(id: "color_b", displayName: "Color B", type: .color, defaultValue: .color(sRGB(red: 0xFF, green: 0xB3, blue: 0x47)), gpuSlot: .slot2RGB)
        ], metadata: .init(displayName: "Gradient Surface", shortDescription: "A static two-color gradient with controllable contrast and radial shaping.", previewConfiguration: .init(recommendedBackground: .dark, alphaBehavior: .opaque)))
    }

    /// Returns the built-in metadata registry. `sourceMap` is intentionally
    /// separate: source assembly and GPU compilation remain consumer concerns.
    public static func registry() throws -> ShaderAssetRegistry {
        try ShaderAssetRegistry([descriptor])
    }

    public static func sourceMap(rootSource: String, colorSource: String,
                                 uvSource: String, gradientSource: String, previewContractSource: String = ShaderPreviewContract.source) -> [String: String] {
        [rootFile: rootSource, "foundation/color.wgsl": colorSource,
         "foundation/uv.wgsl": uvSource, "foundation/gradient.wgsl": gradientSource,
         "foundation/preview_contract.wgsl": previewContractSource,
        ]
    }

    /// Loads the package resources under their stable logical source names.
    /// The explicit map keeps WGSL include resolution independent of SwiftPM's
    /// physical resource layout.
    public static func bundledSourceMap() throws -> [String: String] {
        try bundledSourceMap(in: .module)
    }

    public static func bundledSourceMap(in bundle: Bundle) throws -> [String: String] {
        try sourceMap(
            rootSource: readResource("gradient_surface", bundle: bundle),
            colorSource: readResource("color", bundle: bundle),
            uvSource: readResource("uv", bundle: bundle),
            gradientSource: readResource("gradient", bundle: bundle)
        )
    }

    public static func assembledBundledSource() throws -> String {
        try assembledBundledSource(in: .module)
    }

    public static func assembledBundledSource(in bundle: Bundle) throws -> String {
        try WGSLSourceAssembler.assemble(root: rootFile, sources: bundledSourceMap(in: bundle))
    }

    private static func sRGB(red: UInt8, green: UInt8, blue: UInt8) -> ShaderColor {
        func linear(_ channel: UInt8) -> Float {
            let value = Float(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return ShaderColor(red: linear(red), green: linear(green), blue: linear(blue))
    }

    private static func readResource(_ name: String, bundle: Bundle) throws -> String {
        guard let url = bundle.url(forResource: name, withExtension: "wgsl") else {
            throw ResourceError.missing(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public enum ResourceError: Swift.Error, Equatable, Sendable { case missing(String) }
}

/// Fixed 16-byte common header plus four 16-byte asset slots (80 bytes total).
public struct ShaderAssetUniformPayload: Equatable, Sendable {
    public let floats: [Float]
    public var data: Data { floats.withUnsafeBufferPointer { Data(buffer: $0) } }

    public enum Error: Swift.Error, Equatable, Sendable { case invalidValues(String), invalidDescriptor }

    public init(descriptor: ShaderAssetDescriptor, values: ShaderParameterValues,
                outputSize: (width: Float, height: Float), contentAspect: Float) throws {
        guard descriptor.parameters.count <= 16 else { throw Error.invalidDescriptor }
        var slots = Array(repeating: Float(0), count: 16)
        for parameter in descriptor.parameters {
            guard let value = values.values[parameter.id] else { throw Error.invalidValues(parameter.id) }
            switch (parameter.gpuSlot, value) {
            case (.slot0X, .float(let v)): slots[0] = v
            case (.slot0Y, .float(let v)): slots[1] = v
            case (.slot0Z, .float(let v)): slots[2] = v
            case (.slot0W, .float(let v)): slots[3] = v
            case (.slot1RGB, .color(let c)): slots[4] = c.red; slots[5] = c.green; slots[6] = c.blue
            case (.slot2RGB, .color(let c)): slots[8] = c.red; slots[9] = c.green; slots[10] = c.blue
            case (.slot3RGB, .color(let c)): slots[12] = c.red; slots[13] = c.green; slots[14] = c.blue
            default: throw Error.invalidValues(parameter.id)
            }
        }
        floats = [outputSize.width, outputSize.height, contentAspect, 0] + slots
    }
}
