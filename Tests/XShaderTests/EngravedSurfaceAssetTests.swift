import Testing
@testable import XShader

@Test func engravedSurfaceDescriptorUsesFixedPreviewABI() throws {
    let descriptor = EngravedSurfaceAsset.descriptor
    try descriptor.validate()
    #expect(descriptor.key == EngravedSurfaceAsset.key)
    #expect(descriptor.input == .optionalColor)
    #expect(descriptor.parameters.count == 7)
    let payload = try ShaderAssetUniformPayload(
        descriptor: descriptor, values: ShaderParameterValues(descriptor: descriptor),
        outputSize: (320, 180), contentAspect: 16.0 / 9.0)
    #expect(payload.floats.count == 20)
    #expect(payload.floats[4..<8].elementsEqual([0.055, 0.22, 0.025, 0.45]))
    #expect(payload.data.count == 80)
}

@Test func engravedSurfaceSourceAssemblyContainsStaticInsetTreatment() throws {
    let source = try EngravedSurfaceAsset.assembledBundledSource()
    #expect(source.contains("fn mask_circle_sdf"))
    #expect(source.contains("fn lighting_fake_bevel"))
    #expect(source.contains("mask_sdf_inner_band"))
    #expect(source.contains("let input_alpha"))
    #expect(source.contains("fn shade"))
    #expect(!source.contains("shader-include:"))
    #expect(!source.contains("uniform time"))
}
