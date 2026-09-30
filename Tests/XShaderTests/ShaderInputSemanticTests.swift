import Testing
@testable import XShader

struct ShaderInputSemanticTests {
    @Test("assets declare the semantic their WGSL actually consumes")
    func assetSemanticInventory() {
        #expect(CartoonSurfaceAsset.descriptor.inputSemantic == .analyticShapeAlphaMask)
        #expect(GlassSurfaceAsset.descriptor.inputSemantic == .analyticShapeAlphaMask)
        #expect(EngravedSurfaceAsset.descriptor.inputSemantic == .analyticShapeAlphaMask)
        #expect(NeonStaticSurfaceAsset.descriptor.inputSemantic == .analyticShapeAlphaMask)
        #expect(GradientSurfaceAsset.descriptor.inputSemantic == .none)
        #expect(StoneSurfaceAsset.descriptor.inputSemantic == .none)
        #expect(GoldSurfaceAsset.descriptor.inputSemantic == .none)
    }

    @Test("legacy input projection stays compatible without erasing semantic")
    func legacyProjection() {
        #expect(CartoonSurfaceAsset.descriptor.input == .optionalColor)
        #expect(ShaderAssetDescriptor.Input.none == ShaderAssetDescriptor(
            key: StoneSurfaceAsset.key, rootSource: "asset.wgsl"
        ).input)
    }
}
