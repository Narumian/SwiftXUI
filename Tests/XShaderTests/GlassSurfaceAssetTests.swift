import Foundation
import Testing
@testable import XShader

@Test func glassDescriptorUsesStableOptionalInputAndValidPreviewSlots() throws {
    let descriptor = GlassSurfaceAsset.descriptor
    try descriptor.validate()
    #expect(descriptor.key == GlassSurfaceAsset.key)
    #expect(descriptor.input == .optionalColor)
    #expect(descriptor.parameters.count == 7)
    #expect(descriptor.parameters.map(\.gpuSlot) == [.slot0X, .slot0Y, .slot0Z, .slot0W, .slot1RGB, .slot2RGB, .slot3RGB])
}

@Test func glassPayloadPacksAllParametersIntoFixed80ByteABI() throws {
    let descriptor = GlassSurfaceAsset.descriptor
    let values = ShaderParameterValues(descriptor: descriptor)
    let payload = try ShaderAssetUniformPayload(descriptor: descriptor, values: values,
                                                outputSize: (320, 180), contentAspect: 320.0 / 180.0)
    #expect(payload.floats.count == 20)
    #expect(payload.data.count == 80)
    #expect(payload.floats[0] == 320)
    #expect(payload.floats[1] == 180)
    #expect(payload.floats[4] == 0.045)
    #expect(payload.floats[7] == 0.72)
}

@Test func bundledGlassSourceAssemblesAllDeclaredPrimitivesAndPresentation() throws {
    let source = try GlassSurfaceAsset.assembledBundledSource()
    #expect(!source.contains("shader-include:"))
    #expect(source.contains("fn mask_circle_sdf"))
    #expect(source.contains("fn gradient_linear_t"))
    #expect(source.contains("fn lighting_rim_from_uv"))
    #expect(source.contains("fn sampling_input_alpha"))
    #expect(source.contains("sampling_input_alpha(textureSample(input_texture, input_sampler, uv))"))
    #expect(source.contains("color_premultiplied_linear_to_srgb"))
    #expect(source.contains("@fragment"))
}
