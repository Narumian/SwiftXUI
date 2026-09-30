// shader-include: foundation/color.wgsl
// shader-include: foundation/uv.wgsl
// shader-include: foundation/mask.wgsl
// shader-include: foundation/lighting.wgsl
// shader-include: foundation/sampling.wgsl
// shader-include: foundation/preview_contract.wgsl

fn shade(uv: vec2<f32>) -> vec4<f32> {
    let centered_uv = uv_aspect_correct(uv, params.content_aspect);
    let distance = mask_circle_sdf(centered_uv, vec2<f32>(0.0, 0.0), 0.36, 1.0);
    let fill = mask_sdf_coverage(distance);
    let outline = max(mask_sdf_coverage(distance),
                      mask_sdf_outer_band(distance, params.slot0.y));
    let bevel = lighting_fake_bevel(distance, centered_uv, params.slot0.x, params.slot0.z);
    var color = mix(params.slot2.rgb, params.slot1.rgb, fill);
    color = color + bevel * fill;
    // Foundation output is premultiplied linear RGBA; the outer coverage is
    // the alpha that makes the outline visible without a dark fringe.
    // A bound input may contribute only its alpha as a game-asset mask. The
    // Previewer binds an opaque white fallback when no texture is selected.
    let input_alpha = sampling_input_alpha(textureSample(input_texture, input_sampler, uv));
    let alpha = outline * input_alpha;
    return vec4<f32>(clamp(color, vec3<f32>(0.0), vec3<f32>(1.0)) * alpha, alpha);
}
