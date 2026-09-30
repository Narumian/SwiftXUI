import Foundation

/// Static neon edge/emission reference asset. The restrained edge falloff is
/// intentionally coordinate-only so the asset remains deterministic and
/// legible at small preview sizes.
public enum NeonStaticSurfaceAsset {
    public static let key = ShaderAssetKey("shader.neon_static_surface")!
    public static let rootFile = "assets/neon_static_surface.wgsl"
    public static let foundationFiles = [
        "foundation/color.wgsl", "foundation/uv.wgsl",
        "foundation/mask.wgsl", "foundation/lighting.wgsl", "foundation/sampling.wgsl"
    ]

    public static var descriptor: ShaderAssetDescriptor {
        ShaderAssetDescriptor(key: key, rootFile: rootFile, parameters: [
            .init(id: "edge_width", displayName: "Edge Width", type: .float,
                  defaultValue: .float(0.045), range: 0.008...0.2, gpuSlot: .slot0X),
            .init(id: "glow_falloff", displayName: "Glow Falloff", type: .float,
                  defaultValue: .float(0.12), range: 0.02...0.45, gpuSlot: .slot0Y),
            .init(id: "emission_strength", displayName: "Emission Strength", type: .float,
                  defaultValue: .float(0.75), range: 0.1...2, gpuSlot: .slot0Z),
            .init(id: "core_strength", displayName: "Core Strength", type: .float,
                  defaultValue: .float(1.0), range: 0.2...2, gpuSlot: .slot0W),
            .init(id: "base_color", displayName: "Base Color", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.012, green: 0.018, blue: 0.07)), gpuSlot: .slot1RGB),
            .init(id: "neon_color", displayName: "Neon Color", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.05, green: 0.72, blue: 1.0)), gpuSlot: .slot2RGB),
            .init(id: "accent_color", displayName: "Accent Color", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.78, green: 0.08, blue: 0.92)), gpuSlot: .slot3RGB)
        ], inputSemantic: .analyticShapeAlphaMask,
           metadata: .init(displayName: "Neon Static Surface",
                           shortDescription: "A static neon-like edge with restrained emission and premultiplied alpha.",
                           previewConfiguration: .init(recommendedBackground: .dark, alphaBehavior: .inputMasked)))
    }

    public static func sourceMap(rootSource: String, colorSource: String, uvSource: String,
                                 maskSource: String, lightingSource: String, previewContractSource: String = ShaderPreviewContract.source,
                                 samplingSource: String = "") -> [String: String] {
        [rootFile: rootSource, "foundation/color.wgsl": colorSource,
         "foundation/uv.wgsl": uvSource, "foundation/mask.wgsl": maskSource,
         "foundation/lighting.wgsl": lightingSource,
         "foundation/sampling.wgsl": samplingSource,
         "foundation/preview_contract.wgsl": previewContractSource,
        ]
    }

    public static func bundledSourceMap() throws -> [String: String] { try bundledSourceMap(in: .module) }

    public static func bundledSourceMap(in bundle: Bundle) throws -> [String: String] {
        try sourceMap(rootSource: readResource("neon_static_surface", bundle: bundle),
                      colorSource: readResource("color", bundle: bundle),
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
