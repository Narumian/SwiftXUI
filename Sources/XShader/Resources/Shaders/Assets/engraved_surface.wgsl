// shader-include: foundation/color.wgsl
// shader-include: foundation/uv.wgsl
// shader-include: foundation/mask.wgsl
// shader-include: foundation/lighting.wgsl
// shader-include: foundation/sampling.wgsl
// shader-include: foundation/preview_contract.wgsl

fn shade(uv: vec2<f32>) -> vec4<f32> {
    let centered_uv = uv_aspect_correct(uv, params.content_aspect);
    let distance = mask_circle_sdf(centered_uv, vec2<f32>(0.0, 0.0), 0.37, 1.0);
    let fill = mask_sdf_coverage(distance);
    let edge = lighting_fake_bevel(distance, centered_uv, params.slot0.x, params.slot0.y);

    // A narrow band just inside the silhouette reads as a carved groove even at 64px.
    let inset = max(params.slot0.x * 0.78, 0.008);
    let groove = mask_sdf_inner_band(distance + inset, params.slot0.z);
    let inner_shadow = groove * params.slot0.w;
    let inner_highlight = groove * (1.0 - params.slot0.w) * 0.45;

    var color = params.slot1.rgb;
    color = mix(color, params.slot2.rgb, inner_shadow);
    color = color + params.slot3.rgb * (edge * 0.55 + inner_highlight);
    let input_alpha = sampling_input_alpha(textureSample(input_texture, input_sampler, uv));
    let alpha = fill * input_alpha;
    return vec4<f32>(clamp(color, vec3<f32>(0.0), vec3<f32>(1.0)) * alpha, alpha);
}
