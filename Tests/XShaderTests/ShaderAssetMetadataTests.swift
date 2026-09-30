import Foundation
import Testing
@testable import XShader

@Test func builtInAssetsExposeAuthoredMetadata() throws {
    let descriptors = [
        GradientSurfaceAsset.descriptor, CartoonSurfaceAsset.descriptor,
        MetallicSurfaceAsset.descriptor, GoldSurfaceAsset.descriptor,
        GlassSurfaceAsset.descriptor, PaperSurfaceAsset.descriptor
    ]

    #expect(descriptors.allSatisfy { !$0.displayName.isEmpty && !$0.shortDescription.isEmpty })
    #expect(descriptors.map(\.displayName).sorted() == [
        "Cartoon Surface", "Glass Surface", "Gold Surface",
        "Gradient Surface", "Metallic Surface", "Paper Surface"
    ].sorted())
    for descriptor in descriptors {
        try descriptor.validate()
    }
}

@Test func metadataInitializerRemainsOptionalForExistingConsumers() throws {
    let key = try #require(ShaderAssetKey("shader.legacy"))
    let descriptor = ShaderAssetDescriptor(key: key, rootSource: "fn main() {}")

    #expect(descriptor.metadata.displayName == key.rawValue)
    #expect(descriptor.previewConfiguration.alphaBehavior == .opaque)
    try descriptor.validate()
}

@Test func previewHintsMatchAlphaAndBackgroundNeeds() {
    #expect(GradientSurfaceAsset.descriptor.previewConfiguration.recommendedBackground == .dark)
    #expect(CartoonSurfaceAsset.descriptor.previewConfiguration.alphaBehavior == .inputMasked)
    #expect(GlassSurfaceAsset.descriptor.previewConfiguration.alphaBehavior == .translucent)
    #expect(PaperSurfaceAsset.descriptor.previewConfiguration.recommendedBackground == .light)
}

@Test func previewBackgroundStateExposesFourStableChoices() throws {
    #expect(ShaderPreviewBackground.allCases.map(\.displayName) == [
        "Light", "Dark", "Neutral", "Checkerboard"
    ])

    let registry = try ShaderAssetRegistry([GradientSurfaceAsset.descriptor])
    var state = try ShaderPreviewState(registry: registry)
    state.background = .neutral
    #expect(state.background == .neutral)

    let encoded = try JSONEncoder().encode(state.background)
    let decoded = try JSONDecoder().decode(ShaderPreviewBackground.self, from: encoded)
    #expect(decoded == .neutral)
}
