import Testing
@testable import XShader

@Test func everyStaticAssetUsesOneSharedPreviewContract() throws {
    let registry = try StaticShaderLibrary.registry()

    for descriptor in registry.all {
        let source = try StaticShaderLibrary.assembledBundledSource(for: descriptor.key)
        #expect(source.components(separatedBy: "struct PreviewParams").count == 2)
        #expect(source.components(separatedBy: "struct VertexOut").count == 2)
        #expect(source.components(separatedBy: "fn vs_main").count == 2)
        #expect(source.components(separatedBy: "fn fs_main").count == 2)
        #expect(source.contains("@group(0) @binding(2) var<uniform> params: PreviewParams"))
        #expect(source.contains("fn shade"))
        #expect(!source.contains("shader-include:"))
    }
}

@Test func previewContractKeepsTheFixedUniformABI() {
    let source = ShaderPreviewContract.source
    #expect(source.contains("output_size: vec2<f32>"))
    #expect(source.contains("slot3: vec4<f32>"))
    #expect(source.contains("@group(0) @binding(0) var input_texture"))
    #expect(source.contains("@group(0) @binding(1) var input_sampler"))
    #expect(source.contains("fn vs_main"))
    #expect(source.contains("fn fs_main"))
}
