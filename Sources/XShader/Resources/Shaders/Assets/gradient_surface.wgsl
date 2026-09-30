// shader-include: foundation/color.wgsl
// shader-include: foundation/uv.wgsl
// shader-include: foundation/gradient.wgsl
// shader-include: foundation/preview_contract.wgsl

fn shade(uv: vec2<f32>) -> vec4<f32> {
    let linear_t = saturate(gradient_linear_t(uv, vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 1.0)));
    let radial_t = saturate(gradient_radial_t(uv, vec2<f32>(0.5, 0.5), 0.72, params.content_aspect));
    let mixed_t = mix(linear_t, radial_t, saturate(params.slot0.w));
    var color = color_mix_linear(params.slot1.rgb, params.slot2.rgb, mix(mixed_t, linear_t, saturate(params.slot0.x)));
    color = color_adjust_saturation(color, params.slot0.y);
    color = color_adjust_contrast(color, params.slot0.z);
    return vec4<f32>(clamp(color, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
