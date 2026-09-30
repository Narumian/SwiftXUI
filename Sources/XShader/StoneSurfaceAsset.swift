import Foundation

/// Restrained, deterministic stone surface for static props and background tiles.
/// Broad coordinate-only variation keeps the material readable at small previews;
/// the speckle control is intentionally capped so it does not turn into noise.
public enum StoneSurfaceAsset {
    public static let key = ShaderAssetKey("shader.stone_surface")!
    public static let rootFile = "assets/stone_surface.wgsl"
    public static let foundationFiles = [
        "foundation/color.wgsl", "foundation/gradient.wgsl", "foundation/noise.wgsl"
    ]

    public static var descriptor: ShaderAssetDescriptor {
        ShaderAssetDescriptor(key: key, rootFile: rootFile, parameters: [
            .init(id: "variation_scale", displayName: "Variation Scale", type: .float,
                  defaultValue: .float(3.8), range: 1.5...10, gpuSlot: .slot0X),
            .init(id: "variation_amount", displayName: "Variation Amount", type: .float,
                  defaultValue: .float(0.22), range: 0...0.5, gpuSlot: .slot0Y),
            .init(id: "speckle_amount", displayName: "Speckle Amount", type: .float,
                  defaultValue: .float(0.035), range: 0...0.1, gpuSlot: .slot0Z),
            .init(id: "seed", displayName: "Seed", type: .float,
                  defaultValue: .float(23), range: 0...1000, gpuSlot: .slot0W),
            .init(id: "base_color", displayName: "Base Stone", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.34, green: 0.35, blue: 0.33)), gpuSlot: .slot1RGB),
            .init(id: "light_color", displayName: "Light Stone", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.58, green: 0.57, blue: 0.52)), gpuSlot: .slot2RGB),
            .init(id: "shadow_color", displayName: "Shadow Stone", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.16, green: 0.17, blue: 0.16)), gpuSlot: .slot3RGB)
        ], metadata: .init(displayName: "Stone Surface", shortDescription: "A matte stone treatment with broad tonal variation and restrained speckle.", previewConfiguration: .init(recommendedBackground: .dark, alphaBehavior: .opaque)))
    }

    public static func sourceMap(rootSource: String, colorSource: String,
                                 gradientSource: String, noiseSource: String, previewContractSource: String = ShaderPreviewContract.source) -> [String: String] {
        [rootFile: rootSource, "foundation/color.wgsl": colorSource,
         "foundation/gradient.wgsl": gradientSource, "foundation/noise.wgsl": noiseSource,
         "foundation/preview_contract.wgsl": previewContractSource,
        ]
    }

    public static func bundledSourceMap() throws -> [String: String] { try bundledSourceMap(in: .module) }

    public static func bundledSourceMap(in bundle: Bundle) throws -> [String: String] {
        try sourceMap(rootSource: readResource("stone_surface", bundle: bundle),
                      colorSource: readResource("color", bundle: bundle),
                      gradientSource: readResource("gradient", bundle: bundle),
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
