// shader-include: foundation/color.wgsl
// shader-include: foundation/gradient.wgsl
// shader-include: foundation/lighting.wgsl
// shader-include: foundation/noise.wgsl
// shader-include: foundation/preview_contract.wgsl

fn shade(uv: vec2<f32>) -> vec4<f32> {
    // A subtle horizontal roll-off keeps the gold dimensional without a moving light.
    let base_t = saturate(gradient_linear_t(uv, vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0)));
    var color = color_mix_linear(params.slot1.rgb, params.slot2.rgb, base_t * 0.72 + 0.14);
    let highlight_position = saturate(params.slot0.x);
    let highlight_width = max(params.slot0.y, 0.02);
    let highlight_band = lighting_highlight_band(uv.x, highlight_position, highlight_width);
    let rim = lighting_rim_from_uv(uv, 0.09, params.slot0.z);
    let grain = (surface_grain(uv, 112.0, 37.0) - 0.5) * params.slot0.w;
    color = color + params.slot3.rgb * (highlight_band * 0.28 + rim) + vec3<f32>(grain);
    return vec4<f32>(clamp(color, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
