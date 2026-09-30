import Testing
@testable import XShader

@Test func sourceAssemblyExpandsInOrderAndDeduplicates() throws {
    let source = try WGSLSourceAssembler.assemble(root: "assets/demo.wgsl", sources: [
        "assets/demo.wgsl": "// shader-include: foundation/color.wgsl\n// shader-include: foundation/uv.wgsl\n// shader-include: foundation/color.wgsl\nroot",
        "foundation/color.wgsl": "color",
        "foundation/uv.wgsl": "uv"
    ])
    #expect(source == "color\nuv\n\nroot")
}

@Test func sourceAssemblyRejectsMissingOutsideRootAndCycle() {
    #expect(throws: WGSLSourceAssembler.Error.missingSource("foundation/missing.wgsl")) {
        try WGSLSourceAssembler.assemble(root: "root", sources: ["root": "// shader-include: foundation/missing.wgsl"])
    }
    #expect(throws: WGSLSourceAssembler.Error.self) {
        try WGSLSourceAssembler.assemble(root: "root", sources: ["root": "// shader-include: assets/other.wgsl"])
    }
    #expect(throws: WGSLSourceAssembler.Error.self) {
        try WGSLSourceAssembler.assemble(root: "root", sources: ["root": "// shader-include: foundation/a.wgsl", "foundation/a.wgsl": "// shader-include: foundation/a.wgsl"])
    }
}

@Test func descriptorValidationAndValueClampingAreDeterministic() throws {
    let descriptor = ShaderAssetDescriptor(key: try #require(ShaderAssetKey("shader.demo")), rootSource: "fn main() {}", parameters: [
        ShaderParameterDescriptor(id: "amount", displayName: "Amount", type: .float, defaultValue: .float(0.5), range: 0...1, gpuSlot: .slot0X)
    ])
    try descriptor.validate()
    var values = ShaderParameterValues(descriptor: descriptor)
    try values.set(.float(2), for: "amount", descriptor: descriptor)
    #expect(values.values["amount"] == .float(1))
}

@Test func gradientSurfaceDefaultsPackIntoFixedSlots() throws {
    let descriptor = GradientSurfaceAsset.descriptor
    try descriptor.validate()
    let payload = try ShaderAssetUniformPayload(
        descriptor: descriptor, values: ShaderParameterValues(descriptor: descriptor),
        outputSize: (320, 180), contentAspect: 16.0 / 9.0)
    #expect(payload.floats.count == 20)
    #expect(payload.floats[0..<4].elementsEqual([320, 180, 16.0 / 9.0, 0]))
    #expect(payload.floats[4..<8].elementsEqual([0.5, 1, 1, 0]))
    #expect(payload.floats[8] > 0 && payload.floats[9] > 0 && payload.floats[10] > 0)
    #expect(payload.floats[12] > 0 && payload.floats[13] > 0 && payload.floats[14] > 0)
    #expect(payload.data.count == 80)
}

@Test func gradientSurfaceResourceNamesAssembleFromInjectedMap() throws {
    let map = GradientSurfaceAsset.sourceMap(
        rootSource: "// shader-include: foundation/color.wgsl\n// shader-include: foundation/uv.wgsl\n// shader-include: foundation/gradient.wgsl\nshade",
        colorSource: "color", uvSource: "uv", gradientSource: "gradient")
    let assembled = try WGSLSourceAssembler.assemble(root: GradientSurfaceAsset.rootFile, sources: map)
    #expect(assembled.contains("color\nuv\ngradient\nshade"))
}

@Test func previewStateGeneratesOrderedControlsAndResetsOnSelection() throws {
    let gradient = GradientSurfaceAsset.descriptor
    let other = ShaderAssetDescriptor(key: try #require(ShaderAssetKey("shader.other")), rootFile: "other.wgsl", parameters: [
        .init(id: "value", displayName: "Value", type: .float, defaultValue: .float(0.25), range: 0...1, gpuSlot: .slot0X)
    ])
    let registry = try ShaderAssetRegistry([gradient, other])
    var state = try ShaderPreviewState(registry: registry, selectedKey: gradient.key)
    #expect(state.controls.map { $0.descriptor.id } == ["gradient_mix", "saturation", "contrast", "radial_amount", "color_a", "color_b"])
    #expect(state.controls[0].kind == .slider)
    #expect(state.controls[4].kind == .colorPicker)
    try state.update(.float(9), forParameter: "saturation")
    #expect(state.controls[1].value == .float(2))
    state.resetParameters()
    #expect(state.controls[1].value == .float(1))
    try state.select(other.key)
    #expect(state.controls.map { $0.descriptor.id } == ["value"])
    #expect(state.controls[0].value == .float(0.25))
}

@Test func bundledGradientSurfaceAssemblesTheRealWGSL() throws {
    let source = try GradientSurfaceAsset.assembledBundledSource()
    #expect(source.contains("fn color_mix_linear"))
    #expect(source.contains("fn gradient_radial_t"))
    #expect(source.contains("fn shade"))
    #expect(!source.contains("shader-include:"))
}

@Test func cartoonSurfaceDescriptorUsesStableFixedSlots() throws {
    let descriptor = CartoonSurfaceAsset.descriptor
    try descriptor.validate()
    #expect(descriptor.input == .optionalColor)
    let values = ShaderParameterValues(descriptor: descriptor)
    let payload = try ShaderAssetUniformPayload(descriptor: descriptor, values: values,
                                                outputSize: (256, 256), contentAspect: 1)
    #expect(payload.floats[4..<8].elementsEqual([0.08, 0.04, 0.35, 0]))
    #expect(payload.floats[8] > 0 && payload.floats[9] > 0 && payload.floats[10] > 0)
    #expect(payload.floats[12] > 0 && payload.floats[13] > 0 && payload.floats[14] > 0)
}

@Test func bundledCartoonSurfaceAssemblesMaskAndLightingPrimitives() throws {
    let source = try CartoonSurfaceAsset.assembledBundledSource()
    #expect(source.contains("fn mask_circle_sdf"))
    #expect(source.contains("fn mask_edge_from_sdf"))
    #expect(source.contains("fn lighting_fake_bevel"))
    #expect(source.contains("fn sampling_input_alpha"))
    #expect(source.contains("sampling_input_alpha(textureSample(input_texture, input_sampler, uv))"))
    #expect(source.contains("fn shade"))
    #expect(!source.contains("shader-include:"))
}

@Test func metallicSurfacePacksDeterministicSeedAndAssemblesNoise() throws {
    let descriptor = MetallicSurfaceAsset.descriptor
    try descriptor.validate()
    let values = ShaderParameterValues(descriptor: descriptor)
    let payload = try ShaderAssetUniformPayload(descriptor: descriptor, values: values,
                                                outputSize: (320, 180), contentAspect: 16.0 / 9.0)
    #expect(payload.floats[7] == 17)
    let repeatPayload = try ShaderAssetUniformPayload(descriptor: descriptor, values: values,
                                                      outputSize: (320, 180), contentAspect: 16.0 / 9.0)
    #expect(payload == repeatPayload)
    var changedSeed = values
    try changedSeed.set(.float(18), for: "seed", descriptor: descriptor)
    let changedPayload = try ShaderAssetUniformPayload(descriptor: descriptor, values: changedSeed,
                                                       outputSize: (320, 180), contentAspect: 16.0 / 9.0)
    #expect(changedPayload != payload)
    let source = try MetallicSurfaceAsset.assembledBundledSource()
    #expect(source.contains("fn noise_hash_2d"))
    #expect(source.contains("fn surface_grain"))
    #expect(source.contains("fn lighting_rim_from_uv"))
    #expect(!source.contains("shader-include:"))
}

@Test func staticShaderLibraryListsAndAssemblesAllReferenceAssets() throws {
    let registry = try StaticShaderLibrary.registry()
    #expect(registry.all.map(\.key) == [
        CartoonSurfaceAsset.key,
        EngravedSurfaceAsset.key,
        GlassSurfaceAsset.key,
        GoldSurfaceAsset.key,
        GradientSurfaceAsset.key,
        MetallicSurfaceAsset.key,
        NeonStaticSurfaceAsset.key,
        PaperSurfaceAsset.key,
        StoneSurfaceAsset.key,
    ])
    for descriptor in registry.all {
        let source = try StaticShaderLibrary.assembledBundledSource(for: descriptor.key)
        #expect(source.contains("fn shade"))
        #expect(!source.contains("shader-include:"))
    }
}
