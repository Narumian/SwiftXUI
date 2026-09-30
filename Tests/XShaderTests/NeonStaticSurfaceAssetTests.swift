import Testing
@testable import XShader

@Test func neonStaticSurfaceDescriptorUsesOptionalInputAndFixedPreviewSlots() throws {
    let descriptor = NeonStaticSurfaceAsset.descriptor
    try descriptor.validate()
    #expect(descriptor.key == NeonStaticSurfaceAsset.key)
    #expect(descriptor.input == .optionalColor)
    #expect(descriptor.parameters.count == 7)
    #expect(descriptor.parameters.map(\.gpuSlot) == [.slot0X, .slot0Y, .slot0Z, .slot0W, .slot1RGB, .slot2RGB, .slot3RGB])
    #expect(descriptor.previewConfiguration.alphaBehavior == .inputMasked)
}

@Test func neonStaticSurfacePayloadUsesFixed80ByteABI() throws {
    let descriptor = NeonStaticSurfaceAsset.descriptor
    let payload = try ShaderAssetUniformPayload(
        descriptor: descriptor, values: ShaderParameterValues(descriptor: descriptor),
        outputSize: (320, 180), contentAspect: 16.0 / 9.0)
    #expect(payload.floats.count == 20)
    #expect(payload.data.count == 80)
    #expect(payload.floats[4..<8].elementsEqual([0.045, 0.12, 0.75, 1.0]))
}

@Test func bundledNeonStaticSurfaceSourceAssemblesEdgeEmissionAndPremultipliedAlpha() throws {
    let source = try NeonStaticSurfaceAsset.assembledBundledSource()
    #expect(!source.contains("shader-include:"))
    #expect(source.contains("fn mask_circle_sdf"))
    #expect(source.contains("fn lighting_rim_from_uv"))
    #expect(source.contains("smoothstep(0.0, falloff, abs(distance))"))
    #expect(source.contains("fn sampling_input_alpha"))
    #expect(source.contains("sampling_input_alpha(textureSample(input_texture, input_sampler, uv))"))
    #expect(source.contains("color_premultiplied_linear_to_srgb"))
    #expect(!source.contains("uniform time"))
    #expect(!source.contains("pulse"))
}
