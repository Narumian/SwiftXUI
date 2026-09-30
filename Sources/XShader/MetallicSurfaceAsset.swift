import Foundation

/// Static stylized metal reference asset. Its grain is coordinate/seed based,
/// which makes identical parameters reproducible without a dynamic driver.
public enum MetallicSurfaceAsset {
    public static let key = ShaderAssetKey("shader.metallic_surface")!
    public static let rootFile = "assets/metallic_surface.wgsl"
    public static let foundationFiles = [
        "foundation/color.wgsl", "foundation/gradient.wgsl",
        "foundation/lighting.wgsl", "foundation/noise.wgsl"
    ]

    public static var descriptor: ShaderAssetDescriptor {
        ShaderAssetDescriptor(key: key, rootFile: rootFile, parameters: [
            .init(id: "highlight_position", displayName: "Highlight Position", type: .float,
                  defaultValue: .float(0.38), range: 0...1, gpuSlot: .slot0X),
            .init(id: "edge_strength", displayName: "Edge Strength", type: .float,
                  defaultValue: .float(0.3), range: 0...1, gpuSlot: .slot0Y),
            .init(id: "grain_amount", displayName: "Grain Amount", type: .float,
                  defaultValue: .float(0.045), range: 0...0.2, gpuSlot: .slot0Z),
            .init(id: "seed", displayName: "Seed", type: .float,
                  defaultValue: .float(17), range: 0...1000, gpuSlot: .slot0W),
            .init(id: "dark_color", displayName: "Dark Color", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.025, green: 0.04, blue: 0.075)), gpuSlot: .slot1RGB),
            .init(id: "metal_color", displayName: "Metal Color", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.22, green: 0.32, blue: 0.5)), gpuSlot: .slot2RGB),
            .init(id: "highlight_color", displayName: "Highlight Color", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.8, green: 0.91, blue: 1)), gpuSlot: .slot3RGB)
        ], metadata: .init(displayName: "Metallic Surface", shortDescription: "A deterministic cool metal treatment with edge lighting and fine grain.", previewConfiguration: .init(recommendedBackground: .dark, alphaBehavior: .opaque)))
    }

    public static func sourceMap(rootSource: String, colorSource: String, gradientSource: String,
                                 lightingSource: String, noiseSource: String, previewContractSource: String = ShaderPreviewContract.source) -> [String: String] {
        [rootFile: rootSource, "foundation/color.wgsl": colorSource,
         "foundation/gradient.wgsl": gradientSource, "foundation/lighting.wgsl": lightingSource,
         "foundation/noise.wgsl": noiseSource,
         "foundation/preview_contract.wgsl": previewContractSource,
        ]
    }

    public static func bundledSourceMap() throws -> [String: String] { try bundledSourceMap(in: .module) }

    public static func bundledSourceMap(in bundle: Bundle) throws -> [String: String] {
        try sourceMap(rootSource: readResource("metallic_surface", bundle: bundle),
                      colorSource: readResource("color", bundle: bundle),
                      gradientSource: readResource("gradient", bundle: bundle),
                      lightingSource: readResource("lighting", bundle: bundle),
                      noiseSource: readResource("noise", bundle: bundle))
    }

    public static func assembledBundledSource() throws -> String {
        try WGSLSourceAssembler.assemble(root: rootFile, sources: bundledSourceMap())
    }

    private static func readResource(_ name: String, bundle: Bundle) throws -> String {
        guard let url = bundle.url(forResource: name, withExtension: "wgsl") else {
            throw ResourceError.missing(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public enum ResourceError: Swift.Error, Equatable, Sendable { case missing(String) }
}
