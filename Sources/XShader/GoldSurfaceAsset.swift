import Foundation

/// Static warm gold reference asset with deterministic, coordinate-only grain.
/// It uses the common 80-byte preview payload and has no scene or time inputs.
public enum GoldSurfaceAsset {
    public static let key = ShaderAssetKey("shader.gold_surface")!
    public static let rootFile = "assets/gold_surface.wgsl"
    public static let foundationFiles = [
        "foundation/color.wgsl", "foundation/gradient.wgsl",
        "foundation/lighting.wgsl", "foundation/noise.wgsl"
    ]

    public static var descriptor: ShaderAssetDescriptor {
        ShaderAssetDescriptor(key: key, rootFile: rootFile, parameters: [
            .init(id: "highlight_position", displayName: "Highlight Position", type: .float,
                  defaultValue: .float(0.42), range: 0...1, gpuSlot: .slot0X),
            .init(id: "highlight_width", displayName: "Highlight Width", type: .float,
                  defaultValue: .float(0.22), range: 0.02...0.6, gpuSlot: .slot0Y),
            .init(id: "rim_strength", displayName: "Rim Strength", type: .float,
                  defaultValue: .float(0.16), range: 0...0.6, gpuSlot: .slot0Z),
            .init(id: "grain_amount", displayName: "Grain Amount", type: .float,
                  defaultValue: .float(0.018), range: 0...0.1, gpuSlot: .slot0W),
            .init(id: "base_color", displayName: "Base Gold", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.33, green: 0.12, blue: 0.012)), gpuSlot: .slot1RGB),
            .init(id: "gold_color", displayName: "Gold Color", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.78, green: 0.39, blue: 0.045)), gpuSlot: .slot2RGB),
            .init(id: "highlight_color", displayName: "Highlight Color", type: .color,
                  defaultValue: .color(ShaderColor(red: 1.0, green: 0.72, blue: 0.2)), gpuSlot: .slot3RGB)
        ], metadata: .init(displayName: "Gold Surface", shortDescription: "A warm gold treatment with a broad highlight, rim light, and subtle grain.", previewConfiguration: .init(recommendedBackground: .dark, alphaBehavior: .opaque)))
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
        try sourceMap(rootSource: readResource("gold_surface", bundle: bundle),
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
