// shader-include: foundation/color.wgsl
// shader-include: foundation/uv.wgsl
// shader-include: foundation/noise.wgsl
// shader-include: foundation/preview_contract.wgsl

fn shade(uv: vec2<f32>) -> vec4<f32> {
    let scale = max(params.slot0.x, 1.0);
    let fine = surface_grain(uv, scale * 1.8, params.slot0.w);
    let fibers = noise_hash_2d(floor(vec2<f32>(uv.x * scale, uv.y * scale * 0.22)), params.slot0.w + 23.0);
    let fiber_tone = (fibers - 0.5) * params.slot0.y;
    let grain_tone = (fine - 0.5) * params.slot0.z;
    let edge = smoothstep(0.0, 0.72, distance(uv, vec2<f32>(0.5)));
    var color = params.slot1.rgb + vec3<f32>(grain_tone + fiber_tone);
    color = color_mix_linear(color, params.slot3.rgb, edge * 0.11);
    color = color_mix_linear(color, params.slot2.rgb, max(fiber_tone, 0.0) * 0.18);
    return vec4<f32>(clamp(color, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
