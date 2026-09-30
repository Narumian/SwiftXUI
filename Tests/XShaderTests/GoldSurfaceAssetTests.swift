import Testing
@testable import XShader

@Test func goldSurfaceDescriptorUsesFixedPreviewSlots() throws {
    let descriptor = GoldSurfaceAsset.descriptor
    try descriptor.validate()
    #expect(descriptor.key == GoldSurfaceAsset.key)
    #expect(descriptor.parameters.count == 7)
    let payload = try ShaderAssetUniformPayload(
        descriptor: descriptor, values: ShaderParameterValues(descriptor: descriptor),
        outputSize: (320, 180), contentAspect: 16.0 / 9.0)
    #expect(payload.floats.count == 20)
    #expect(payload.floats[4..<8].elementsEqual([0.42, 0.22, 0.16, 0.018]))
    #expect(payload.floats[8] > payload.floats[10])
    #expect(payload.floats[12] > payload.floats[13])
    #expect(payload.data.count == 80)
}

@Test func goldSurfaceSourceAssemblyIncludesStaticGoldPrimitives() throws {
    let source = try GoldSurfaceAsset.assembledBundledSource()
    #expect(source.contains("fn gradient_linear_t"))
    #expect(source.contains("fn lighting_rim_from_uv"))
    #expect(source.contains("fn surface_grain"))
    #expect(source.contains("fn shade"))
    #expect(source.contains("surface_grain(uv, 112.0, 37.0)"))
    #expect(!source.contains("shader-include:"))
    #expect(!source.contains("uniform time"))
}
