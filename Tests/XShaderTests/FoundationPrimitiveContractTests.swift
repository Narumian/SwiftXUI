import Foundation
import Testing
@testable import XShader

@Test func foundationPrimitiveContractsStaySmallAndStatic() throws {
    let source = try WGSLSourceAssembler.assemble(root: "assets/demo.wgsl", sources: [
        "assets/demo.wgsl": "// shader-include: foundation/math.wgsl\n// shader-include: foundation/uv.wgsl\n// shader-include: foundation/sampling.wgsl\n// shader-include: foundation/mask.wgsl\nshade",
        "foundation/math.wgsl": "fn math_remap_clamped(value: f32, input_min: f32, input_max: f32, output_min: f32, output_max: f32) -> f32 { return value; }",
        "foundation/uv.wgsl": "fn uv_scale_centered(uv: vec2<f32>, scale: vec2<f32>, center: vec2<f32>) -> vec2<f32> { return uv; }\nfn uv_offset(uv: vec2<f32>, offset: vec2<f32>) -> vec2<f32> { return uv; }\nfn uv_rotate_centered(uv: vec2<f32>, radians: f32, center: vec2<f32>) -> vec2<f32> { return uv; }",
        "foundation/sampling.wgsl": "fn sampling_input_alpha(sample: vec4<f32>) -> f32 { return sample.a; }",
        "foundation/mask.wgsl": "fn mask_sdf_coverage(distance: f32) -> f32 { return distance; }\nfn mask_rounded_rect_sdf(uv: vec2<f32>, center: vec2<f32>, half_extent: vec2<f32>, radius: f32, aspect: f32) -> f32 { return radius; }\nfn mask_sdf_union(a: f32, b: f32) -> f32 { return a; }\nfn mask_sdf_intersection(a: f32, b: f32) -> f32 { return a; }"
    ])
    #expect(source.contains("fn math_remap_clamped"))
    #expect(source.contains("fn uv_rotate_centered"))
    #expect(source.contains("fn sampling_input_alpha"))
    #expect(source.contains("fn mask_sdf_coverage"))
    #expect(source.contains("fn mask_rounded_rect_sdf"))
    #expect(source.contains("fn mask_sdf_union"))
    #expect(source.contains("fn mask_sdf_intersection"))
    #expect(!source.contains("time"))
}

@Test func foundationNestedIncludesAreExpandedOnce() throws {
    let source = try WGSLSourceAssembler.assemble(root: "assets/demo.wgsl", sources: [
        "assets/demo.wgsl": "// shader-include: foundation/mask.wgsl\nroot",
        "foundation/mask.wgsl": "// shader-include: foundation/math.wgsl\nmask",
        "foundation/math.wgsl": "math"
    ])
    #expect(source == "math\nmask\nroot")
}

@Test func sdfBandContractsUseSignedDistanceAndHaveMultipleConsumers() throws {
    let maskURL = try #require(Bundle.module.url(forResource: "mask", withExtension: "wgsl"))
    let maskSource = try String(contentsOf: maskURL, encoding: .utf8)
    #expect(maskSource.contains("distance < 0") || maskSource.contains("inside"))
    #expect(maskSource.contains("fn mask_sdf_coverage"))
    #expect(maskSource.contains("fn mask_sdf_inner_band"))
    #expect(maskSource.contains("fn mask_sdf_outer_band"))
    #expect(maskSource.contains("fwidth(distance)"))

    let cartoon = try CartoonSurfaceAsset.assembledBundledSource()
    let glass = try GlassSurfaceAsset.assembledBundledSource()
    let engraved = try EngravedSurfaceAsset.assembledBundledSource()
    #expect(cartoon.contains("mask_sdf_outer_band"))
    #expect(glass.contains("mask_sdf_outer_band"))
    #expect(engraved.contains("mask_sdf_inner_band"))
    #expect(!cartoon.contains("mask_smooth_edge(distance, 0.006)"))
    #expect(!glass.contains("mask_smooth_edge(distance, 0.006)"))
    #expect(!engraved.contains("abs(distance + inset)"))
}
