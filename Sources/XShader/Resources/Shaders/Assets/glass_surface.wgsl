// shader-include: foundation/color.wgsl
// shader-include: foundation/gradient.wgsl
// shader-include: foundation/uv.wgsl
// shader-include: foundation/mask.wgsl
// shader-include: foundation/lighting.wgsl
// shader-include: foundation/sampling.wgsl
// shader-include: foundation/preview_contract.wgsl

fn shade(uv: vec2<f32>) -> vec4<f32> {
    let centered_uv = uv_aspect_correct(uv, params.content_aspect);
    let distance = mask_circle_sdf(centered_uv, vec2<f32>(0.0, 0.0), 0.42, 1.0);
    let fill = mask_sdf_coverage(distance);
    let outline = max(mask_sdf_coverage(distance),
                      mask_sdf_outer_band(distance, params.slot0.x));
    let input_alpha = sampling_input_alpha(textureSample(input_texture, input_sampler, uv));
    let alpha = outline * input_alpha * saturate(params.slot0.w);

    let vertical_t = saturate(gradient_linear_t(uv, vec2<f32>(0.0, 0.0), vec2<f32>(0.0, 1.0)));
    let cool_shade = color_mix_linear(params.slot3.rgb, params.slot1.rgb, vertical_t);
    let highlight = 1.0 - smoothstep(0.0, 0.22, abs(uv.x - saturate(params.slot0.z)));
    let bevel = lighting_fake_bevel(distance, centered_uv, params.slot0.x, params.slot0.y);
    let rim = lighting_rim_from_uv(uv, params.slot0.x, params.slot0.y);
    let glass_color = cool_shade * (0.42 + 0.28 * fill)
        + params.slot2.rgb * (0.32 * highlight + 0.5 * bevel + 0.25 * rim);
    return vec4<f32>(clamp(glass_color, vec3<f32>(0.0), vec3<f32>(1.0)) * alpha, alpha);
}
