// shader-include: foundation/color.wgsl
// shader-include: foundation/gradient.wgsl
// shader-include: foundation/noise.wgsl
// shader-include: foundation/preview_contract.wgsl

fn stone_broad_variation(uv: vec2<f32>, scale: f32, seed: f32) -> f32 {
    let coarse = surface_grain(uv, max(scale, 1.0), seed);
    let broad = surface_grain(uv, max(scale * 0.35, 1.0), seed + 41.0);
    return mix(coarse, broad, 0.72);
}

fn shade(uv: vec2<f32>) -> vec4<f32> {
    let scale = params.slot0.x;
    let broad = stone_broad_variation(uv, scale, params.slot0.w);
    let tonal = saturate(0.5 + (broad - 0.5) * 1.35);
    var color = color_mix_linear(params.slot3.rgb, params.slot1.rgb, tonal);
    let warm_plane = saturate(gradient_linear_t(uv, vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 1.0)));
    color = color_mix_linear(color, params.slot2.rgb, 0.12 + 0.08 * (1.0 - warm_plane));
    let speckle = (surface_grain(uv, 26.0, params.slot0.w + 19.0) - 0.5) * params.slot0.z;
    color = color + vec3<f32>(speckle) + vec3<f32>((tonal - 0.5) * params.slot0.y);
    return vec4<f32>(clamp(color, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
