import Foundation

/// A static, mask-driven engraved surface with a restrained inset line and depth cue.
/// The asset is intentionally coordinate-only: it has no time, scene, or dynamic-light input.
public enum EngravedSurfaceAsset {
    public static let key = ShaderAssetKey("shader.engraved_surface")!
    public static let rootFile = "assets/engraved_surface.wgsl"
    public static let foundationFiles = [
        "foundation/color.wgsl", "foundation/uv.wgsl",
        "foundation/mask.wgsl", "foundation/lighting.wgsl", "foundation/sampling.wgsl"
    ]

    public static var descriptor: ShaderAssetDescriptor {
        ShaderAssetDescriptor(key: key, rootFile: rootFile, parameters: [
            .init(id: "edge_width", displayName: "Edge Width", type: .float,
                  defaultValue: .float(0.055), range: 0.005...0.2, gpuSlot: .slot0X),
            .init(id: "depth_strength", displayName: "Depth Strength", type: .float,
                  defaultValue: .float(0.22), range: 0...0.8, gpuSlot: .slot0Y),
            .init(id: "line_width", displayName: "Engraved Line Width", type: .float,
                  defaultValue: .float(0.025), range: 0.003...0.12, gpuSlot: .slot0Z),
            .init(id: "line_strength", displayName: "Line Strength", type: .float,
                  defaultValue: .float(0.45), range: 0...1, gpuSlot: .slot0W),
            .init(id: "base_color", displayName: "Base Color", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.20, green: 0.16, blue: 0.12)), gpuSlot: .slot1RGB),
            .init(id: "groove_color", displayName: "Groove Color", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.045, green: 0.030, blue: 0.022)), gpuSlot: .slot2RGB),
            .init(id: "highlight_color", displayName: "Edge Highlight", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.64, green: 0.49, blue: 0.30)), gpuSlot: .slot3RGB)
        ], inputSemantic: .analyticShapeAlphaMask, metadata: .init(
            displayName: "Engraved Surface",
            shortDescription: "A quiet embossed plate with a readable inset line and static edge depth.",
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
        try sourceMap(rootSource: readResource("engraved_surface", bundle: bundle),
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
