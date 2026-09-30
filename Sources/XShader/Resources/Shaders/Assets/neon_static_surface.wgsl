// shader-include: foundation/color.wgsl
// shader-include: foundation/uv.wgsl
// shader-include: foundation/mask.wgsl
// shader-include: foundation/lighting.wgsl
// shader-include: foundation/sampling.wgsl
// shader-include: foundation/preview_contract.wgsl

fn shade(uv: vec2<f32>) -> vec4<f32> {
    let centered_uv = uv_aspect_correct(uv, params.content_aspect);
    let distance = mask_circle_sdf(centered_uv, vec2<f32>(0.0, 0.0), 0.42, 1.0);
    let edge_width = max(params.slot0.x, 0.0001);
    let falloff = max(params.slot0.y, 0.0001);
    let core = 1.0 - smoothstep(0.0, edge_width, abs(distance));
    let glow = 1.0 - smoothstep(0.0, falloff, abs(distance));
    let rim = lighting_rim_from_uv(uv, 0.16, 0.22);
    let input_alpha = sampling_input_alpha(textureSample(input_texture, input_sampler, uv));
    let alpha = saturate(max(core, glow * 0.42) * input_alpha);
    let accent_t = saturate(uv.y * 0.7 + uv.x * 0.3);
    let edge_color = color_mix_linear(params.slot2.rgb, params.slot3.rgb, accent_t);
    let emission = edge_color * (glow * params.slot0.z + core * params.slot0.w);
    let body = params.slot1.rgb * (0.18 + 0.16 * (1.0 - core)) + emission + vec3<f32>(rim * 0.04);
    let premultiplied = clamp(body, vec3<f32>(0.0), vec3<f32>(1.0)) * alpha;
    return vec4<f32>(premultiplied, alpha);
}
