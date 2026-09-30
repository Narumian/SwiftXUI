import Foundation

/// A small static 2D reference asset validating mask, edge, and fake bevel primitives.
public enum CartoonSurfaceAsset {
    public static let key = ShaderAssetKey("shader.cartoon_surface")!
    public static let rootFile = "assets/cartoon_surface.wgsl"
    public static let foundationFiles = [
        "foundation/color.wgsl", "foundation/uv.wgsl",
        "foundation/mask.wgsl", "foundation/lighting.wgsl", "foundation/sampling.wgsl"
    ]

    public static var descriptor: ShaderAssetDescriptor {
        ShaderAssetDescriptor(key: key, rootFile: rootFile, parameters: [
            .init(id: "bevel_width", displayName: "Bevel Width", type: .float,
                  defaultValue: .float(0.08), range: 0...0.25, gpuSlot: .slot0X),
            .init(id: "outline_width", displayName: "Outline Width", type: .float,
                  defaultValue: .float(0.04), range: 0.001...0.2, gpuSlot: .slot0Y),
            .init(id: "highlight_strength", displayName: "Highlight Strength", type: .float,
                  defaultValue: .float(0.35), range: 0...1, gpuSlot: .slot0Z),
            .init(id: "base_color", displayName: "Base Color", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.18, green: 0.42, blue: 0.9)), gpuSlot: .slot1RGB),
            .init(id: "outline_color", displayName: "Outline Color", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.025, green: 0.035, blue: 0.08)), gpuSlot: .slot2RGB)
        ], inputSemantic: .analyticShapeAlphaMask, metadata: .init(displayName: "Cartoon Surface", shortDescription: "A mask-driven stylized surface with outline and soft bevel lighting.", previewConfiguration: .init(recommendedBackground: .checker, alphaBehavior: .inputMasked)))
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
        try sourceMap(rootSource: readResource("cartoon_surface", bundle: bundle),
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
