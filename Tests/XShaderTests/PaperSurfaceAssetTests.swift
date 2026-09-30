import Testing
@testable import XShader

@Test func paperSurfaceDescriptorUsesSevenStableParametersAndFixedPayload() throws {
    let descriptor = PaperSurfaceAsset.descriptor
    try descriptor.validate()
    #expect(descriptor.key == PaperSurfaceAsset.key)
    #expect(descriptor.parameters.count == 7)
    let payload = try ShaderAssetUniformPayload(descriptor: descriptor,
        values: ShaderParameterValues(descriptor: descriptor), outputSize: (320, 180), contentAspect: 16.0 / 9.0)
    #expect(payload.floats.count == 20)
    #expect(payload.floats[4..<8].elementsEqual([84, 0.16, 0.07, 17]))
    #expect(payload.floats[8] > 0 && payload.floats[9] > 0 && payload.floats[10] > 0)
    #expect(payload.floats[12] > 0 && payload.floats[13] > 0 && payload.floats[14] > 0)
    #expect(payload.data.count == 80)
}

@Test func paperSurfaceSourceAssemblyUsesInjectedFoundationSources() throws {
    let map = PaperSurfaceAsset.sourceMap(
        rootSource: "// shader-include: foundation/color.wgsl\n// shader-include: foundation/uv.wgsl\n// shader-include: foundation/noise.wgsl\nshade",
        colorSource: "color", uvSource: "uv", noiseSource: "noise")
    let assembled = try WGSLSourceAssembler.assemble(root: PaperSurfaceAsset.rootFile, sources: map)
    #expect(assembled == "color\nuv\nnoise\nshade")
}

@Test func bundledPaperSurfaceAssemblesDeterministicFiberShader() throws {
    let source = try PaperSurfaceAsset.assembledBundledSource()
    #expect(source.contains("fn noise_hash_2d"))
    #expect(source.contains("fn surface_grain"))
    #expect(source.contains("fiber_tone"))
    #expect(source.contains("fn shade"))
    #expect(!source.contains("shader-include:"))
}
