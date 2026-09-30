import Foundation

/// Static translucent glass reference asset. The highlight and rim are entirely
/// coordinate-driven so the result is deterministic and needs no time input.
public enum GlassSurfaceAsset {
    public static let key = ShaderAssetKey("shader.glass_surface")!
    public static let rootFile = "assets/glass_surface.wgsl"
    public static let foundationFiles = [
        "foundation/color.wgsl", "foundation/gradient.wgsl", "foundation/uv.wgsl",
        "foundation/mask.wgsl", "foundation/lighting.wgsl", "foundation/sampling.wgsl"
    ]

    public static var descriptor: ShaderAssetDescriptor {
        ShaderAssetDescriptor(key: key, rootFile: rootFile, parameters: [
            .init(id: "edge_width", displayName: "Edge Width", type: .float,
                  defaultValue: .float(0.045), range: 0...0.2, gpuSlot: .slot0X),
            .init(id: "edge_strength", displayName: "Edge Strength", type: .float,
                  defaultValue: .float(0.75), range: 0...2, gpuSlot: .slot0Y),
            .init(id: "highlight_position", displayName: "Highlight Position", type: .float,
                  defaultValue: .float(0.28), range: 0...1, gpuSlot: .slot0Z),
            .init(id: "opacity", displayName: "Opacity", type: .float,
                  defaultValue: .float(0.72), range: 0...1, gpuSlot: .slot0W),
            .init(id: "tint", displayName: "Glass Tint", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.25, green: 0.72, blue: 0.9)), gpuSlot: .slot1RGB),
            .init(id: "reflection", displayName: "Reflection", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.8, green: 0.96, blue: 1)), gpuSlot: .slot2RGB),
            .init(id: "shadow", displayName: "Shadow Tint", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.025, green: 0.08, blue: 0.14)), gpuSlot: .slot3RGB)
        ], inputSemantic: .analyticShapeAlphaMask, metadata: .init(displayName: "Glass Surface", shortDescription: "A translucent glass treatment with tinted edges and coordinate-driven reflection.", previewConfiguration: .init(recommendedBackground: .checker, alphaBehavior: .translucent)))
    }

    public static func sourceMap(rootSource: String, colorSource: String, gradientSource: String,
                                 uvSource: String, maskSource: String, lightingSource: String, previewContractSource: String = ShaderPreviewContract.source,
                                 samplingSource: String = "") -> [String: String] {
        [rootFile: rootSource, "foundation/color.wgsl": colorSource,
         "foundation/gradient.wgsl": gradientSource, "foundation/uv.wgsl": uvSource,
         "foundation/mask.wgsl": maskSource, "foundation/lighting.wgsl": lightingSource,
         "foundation/sampling.wgsl": samplingSource,
         "foundation/preview_contract.wgsl": previewContractSource,
        ]
    }

    public static func bundledSourceMap() throws -> [String: String] { try bundledSourceMap(in: .module) }

    public static func bundledSourceMap(in bundle: Bundle) throws -> [String: String] {
        try sourceMap(rootSource: readResource("glass_surface", bundle: bundle),
                      colorSource: readResource("color", bundle: bundle),
                      gradientSource: readResource("gradient", bundle: bundle),
                      uvSource: readResource("uv", bundle: bundle),
                      maskSource: readResource("mask", bundle: bundle),
                      lightingSource: readResource("lighting", bundle: bundle),
                      samplingSource: readResource("sampling", bundle: bundle))
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
