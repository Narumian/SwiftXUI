/// Sprite pipeline WGSL: a textured quad multiplied by a premultiplied tint.
/// Bind group 0 = { texture_2d, sampler }. Vertex layout matches
/// `SceneCompiler` sprite output: pos(2) + uv(2) + tint(4), stride 32 bytes.
let spriteWGSL = """
struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) tint: vec4<f32>,
};

@group(0) @binding(0) var spriteTexture: texture_2d<f32>;
@group(0) @binding(1) var spriteSampler: sampler;

@vertex
fn vs_main(
    @location(0) position: vec2<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) tint: vec4<f32>
) -> VertexOut {
    var out: VertexOut;
    out.position = vec4<f32>(position, 0.0, 1.0);
    out.uv = uv;
    out.tint = tint;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    return textureSample(spriteTexture, spriteSampler, in.uv) * in.tint;
}
"""
