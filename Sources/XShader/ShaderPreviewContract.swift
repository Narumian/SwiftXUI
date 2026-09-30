import Foundation

/// Default source used by the injectable asset source-map helpers.
/// Bundled assembly reads the canonical WGSL resource instead.
public enum ShaderPreviewContract {
    public static let source = """
    struct PreviewParams {
        output_size: vec2<f32>,
        content_aspect: f32,
        reserved0: f32,
        slot0: vec4<f32>,
        slot1: vec4<f32>,
        slot2: vec4<f32>,
        slot3: vec4<f32>,
    };

    struct VertexOut {
        @builtin(position) position: vec4<f32>,
        @location(0) uv: vec2<f32>,
    };

    @group(0) @binding(0) var input_texture: texture_2d<f32>;
    @group(0) @binding(1) var input_sampler: sampler;
    @group(0) @binding(2) var<uniform> params: PreviewParams;

    @vertex
    fn vs_main(@builtin(vertex_index) index: u32) -> VertexOut {
        var positions = array<vec2<f32>, 3>(
            vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0)
        );
        let position = positions[index];
        var out: VertexOut;
        out.position = vec4<f32>(position, 0.0, 1.0);
        out.uv = vec2<f32>(position.x * 0.5 + 0.5, 0.5 - position.y * 0.5);
        return out;
    }

    @fragment
    fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
        let output = shade(in.uv);
        return vec4<f32>(color_premultiplied_linear_to_srgb(output.rgb, output.a), output.a);
    }
    """
}
