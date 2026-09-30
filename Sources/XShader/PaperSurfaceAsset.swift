import Foundation

/// A quiet, deterministic paper surface for static game backgrounds and panels.
public enum PaperSurfaceAsset {
    public static let key = ShaderAssetKey("shader.paper_surface")!
    public static let rootFile = "assets/paper_surface.wgsl"
    public static let foundationFiles = [
        "foundation/color.wgsl", "foundation/uv.wgsl", "foundation/noise.wgsl"
    ]

    public static var descriptor: ShaderAssetDescriptor {
        ShaderAssetDescriptor(key: key, rootFile: rootFile, parameters: [
            .init(id: "fiber_scale", displayName: "Fiber Scale", type: .float,
                  defaultValue: .float(84), range: 8...220, gpuSlot: .slot0X),
            .init(id: "fiber_strength", displayName: "Fiber Strength", type: .float,
                  defaultValue: .float(0.16), range: 0...1, gpuSlot: .slot0Y),
            .init(id: "grain_amount", displayName: "Grain Amount", type: .float,
                  defaultValue: .float(0.07), range: 0...0.35, gpuSlot: .slot0Z),
            .init(id: "seed", displayName: "Seed", type: .float,
                  defaultValue: .float(17), range: 0...1000, gpuSlot: .slot0W),
            .init(id: "base_color", displayName: "Base Color", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.78, green: 0.72, blue: 0.60)), gpuSlot: .slot1RGB),
            .init(id: "fiber_color", displayName: "Fiber Color", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.32, green: 0.25, blue: 0.16)), gpuSlot: .slot2RGB),
            .init(id: "shadow_color", displayName: "Shadow Color", type: .color,
                  defaultValue: .color(ShaderColor(red: 0.16, green: 0.11, blue: 0.07)), gpuSlot: .slot3RGB)
        ], metadata: .init(displayName: "Paper Surface", shortDescription: "A quiet paper treatment with deterministic fibers, grain, and shadow variation.", previewConfiguration: .init(recommendedBackground: .light, alphaBehavior: .opaque)))
    }

    public static func sourceMap(rootSource: String, colorSource: String,
                                 uvSource: String, noiseSource: String, previewContractSource: String = ShaderPreviewContract.source) -> [String: String] {
        [rootFile: rootSource, "foundation/color.wgsl": colorSource,
         "foundation/uv.wgsl": uvSource, "foundation/noise.wgsl": noiseSource,
         "foundation/preview_contract.wgsl": previewContractSource,
        ]
    }

    public static func bundledSourceMap() throws -> [String: String] { try bundledSourceMap(in: .module) }

    public static func bundledSourceMap(in bundle: Bundle) throws -> [String: String] {
        try sourceMap(rootSource: readResource("paper_surface", bundle: bundle),
                      colorSource: readResource("color", bundle: bundle),
                      uvSource: readResource("uv", bundle: bundle),
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
