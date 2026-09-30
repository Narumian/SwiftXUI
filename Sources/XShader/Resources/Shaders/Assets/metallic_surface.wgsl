// shader-include: foundation/color.wgsl
// shader-include: foundation/gradient.wgsl
// shader-include: foundation/lighting.wgsl
// shader-include: foundation/noise.wgsl
// shader-include: foundation/preview_contract.wgsl

fn shade(uv: vec2<f32>) -> vec4<f32> {
    let base_t = saturate(gradient_linear_t(uv, vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0)));
    var color = color_mix_linear(params.slot1.rgb, params.slot2.rgb, base_t);
    let highlight_position = saturate(params.slot0.x);
    let highlight_band = lighting_highlight_band(uv.x, highlight_position, 0.24);
    let edge = lighting_rim_from_uv(uv, 0.075, params.slot0.y);
    let grain = (surface_grain(uv, 96.0, params.slot0.w) - 0.5) * params.slot0.z;
    color = color + params.slot3.rgb * (highlight_band * 0.55 + edge) + vec3<f32>(grain);
    return vec4<f32>(clamp(color, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
