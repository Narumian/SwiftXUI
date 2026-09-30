import Testing
@testable import XShader

@Test func stoneSurfaceDescriptorUsesSevenStableParametersAndOpaqueMetadata() throws {
    let descriptor = StoneSurfaceAsset.descriptor
    try descriptor.validate()
    #expect(descriptor.parameters.count == 7)
    #expect(descriptor.input == .none)
    #expect(descriptor.previewConfiguration.recommendedBackground == .dark)
    #expect(descriptor.previewConfiguration.alphaBehavior == .opaque)
}

@Test func stoneSurfaceDefaultsPackIntoFixedEightyBytePayload() throws {
    let descriptor = StoneSurfaceAsset.descriptor
    let payload = try ShaderAssetUniformPayload(
        descriptor: descriptor, values: ShaderParameterValues(descriptor: descriptor),
        outputSize: (64, 64), contentAspect: 1)
    #expect(payload.floats.count == 20)
    #expect(payload.floats[4..<8].elementsEqual([3.8, 0.22, 0.035, 23]))
    #expect(payload.data.count == 80)
}

@Test func stoneSurfaceSourceAssemblyExpandsOnlyDeclaredFoundationInputs() throws {
    let map = StoneSurfaceAsset.sourceMap(
        rootSource: "// shader-include: foundation/color.wgsl\n// shader-include: foundation/gradient.wgsl\n// shader-include: foundation/noise.wgsl\nshade",
        colorSource: "color", gradientSource: "gradient", noiseSource: "noise")
    let assembled = try WGSLSourceAssembler.assemble(root: StoneSurfaceAsset.rootFile, sources: map)
    #expect(assembled == "color\ngradient\nnoise\nshade")
}

@Test func bundledStoneSurfaceContainsBroadNoiseAndNoDynamicDriver() throws {
    let source = try StoneSurfaceAsset.assembledBundledSource()
    #expect(source.contains("fn stone_broad_variation"))
    #expect(source.contains("fn noise_hash_2d"))
    #expect(source.contains("fn surface_grain"))
    #expect(source.contains("fn shade"))
    #expect(!source.contains("shader-include:"))
    #expect(!source.contains("@binding(3)"))
}
