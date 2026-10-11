/// Fullscreen post pass: ordered dither + understated VHS (edge chromatic
/// aberration, faint scanlines, fine grain). Bind group 0 = { scene texture,
/// sampler, uniforms }. No vertex buffer — a 3-vertex fullscreen triangle.
let postWGSL = """
struct Effect {
    rect: vec4<f32>,
    params: vec4<f32>,
    params2: vec4<f32>,
    params3: vec4<f32>,
    kind: f32,
};

struct Uniforms {
    resolution: vec2<f32>,
    time: f32,
    intensity: f32,
    effectCount: f32,
    // 0 = final opaque post pass; 1 = alpha-composite a transparent view layer.
    composition: f32,
    // distance = depthA / (depthB - depth); depthFocus is the distance to the camera's target.
    depthA: f32,
    depthB: f32,
    depthFocus: f32,
    effects: array<Effect, 16>,
};

@group(0) @binding(0) var sceneTexture: texture_2d<f32>;
@group(0) @binding(1) var sceneSampler: sampler;
@group(0) @binding(2) var<uniform> u: Uniforms;
// The scene depth of the last X3D pass that drew with depth; a 1x1 stand-in when none did.
@group(0) @binding(3) var depthTexture: texture_depth_2d;

@vertex
fn vs_main(@builtin(vertex_index) vertexIndex: u32) -> @builtin(position) vec4<f32> {
    var p = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    return vec4<f32>(p[vertexIndex], 0.0, 1.0);
}

fn bayer(p: vec2<u32>) -> f32 {
    var m = array<f32, 16>(
        0.0, 8.0, 2.0, 10.0,
        12.0, 4.0, 14.0, 6.0,
        3.0, 11.0, 1.0, 9.0,
        15.0, 7.0, 13.0, 5.0
    );
    return m[(p.y & 3u) * 4u + (p.x & 3u)] / 16.0 - 0.5;
}

@fragment
fn fs_main(@builtin(position) fragCoord: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = fragCoord.xy / u.resolution;
    let source = textureSample(sceneTexture, sceneSampler, uv);
    // A layer capture is transparent outside the actual subtree. Never let an
    // effect's tint/rim paint those empty pixels: doing so turns the layer's
    // rectangular bounds into a visible, corrupted-looking slab on composite.
    let layerMask = select(1.0, source.a, u.composition == 1.0);
    let edge = abs(uv.x - 0.5) * 2.0;
    let shift = edge * edge * 1.8 * u.intensity / u.resolution.x;

    var alpha = select(1.0, source.a, u.composition == 1.0);
    var col: vec3<f32>;
    col.r = textureSample(sceneTexture, sceneSampler, uv + vec2<f32>(shift, 0.0)).r;
    col.g = textureSample(sceneTexture, sceneSampler, uv).g;
    col.b = textureSample(sceneTexture, sceneSampler, uv - vec2<f32>(shift, 0.0)).b;

    let scan = 1.0 - u.intensity * 0.05 * step(2.0, (fragCoord.y - floor(fragCoord.y / 3.0) * 3.0));
    col = col * scan;

    let d = bayer(vec2<u32>(u32(fragCoord.x), u32(fragCoord.y))) * (2.5 / 255.0);
    let n = fract(sin(dot(fragCoord.xy + vec2<f32>(u.time), vec2<f32>(12.9898, 78.233))) * 43758.5453);
    let grain = (n - 0.5) * (3.0 / 255.0);
    col = col + vec3<f32>((d + grain) * u.intensity);

    // Region effects are deliberately small and bounded: the CPU supplies up
    // to sixteen rects, while unknown shader keys are encoded as kind 0 and
    // become no-ops. This keeps the post pipeline portable and predictable.
    for (var i = 0u; i < 16u; i = i + 1u) {
        if (f32(i) >= u.effectCount) { break; }
        let effect = u.effects[i];
        let minUV = effect.rect.xy / u.resolution;
        let maxUV = (effect.rect.xy + effect.rect.zw) / u.resolution;
        let inside = step(minUV.x, uv.x) * step(minUV.y, uv.y)
                   * step(uv.x, maxUV.x) * step(uv.y, maxUV.y);
        let local = clamp((uv - minUV) / max(effect.rect.zw / u.resolution, vec2<f32>(0.001)),
                          vec2<f32>(0.0), vec2<f32>(1.0));

        if (effect.kind == 1.0) {
            // Cell glow: a soft border plus a small accent tint.
            let edge = min(min(local.x, 1.0 - local.x), min(local.y, 1.0 - local.y));
            let glow = (1.0 - smoothstep(0.0, 0.18, edge)) * effect.params.w * inside * layerMask;
            col = col + effect.params.rgb * glow * 0.45;
        } else if (effect.kind == 2.0) {
            // Cell shine: a diagonal band travelling across the cell.
            let band = 1.0 - smoothstep(0.0, 0.16,
                abs(local.x + local.y - 1.8 - effect.params.w * 2.4));
            col = col + effect.params.rgb * band * inside * layerMask * 0.7;
        } else if (effect.kind == 3.0) {
            // Hit flash: preserve alpha while biasing the source toward white.
            let flash = clamp(effect.params.x, 0.0, 1.0) * inside * layerMask;
            col = mix(col, vec3<f32>(1.0), flash * 0.8);
        } else if (effect.kind == 4.0) {
            // Glass: a restrained cool tint, animated refraction, and a bright
            // rim. It is intentionally local so the whole reel panel can read
            // as one surface without affecting the rest of the battle scene.
            let amount = clamp(effect.params.w, 0.0, 1.0) * inside * layerMask;
            let rim = (1.0 - smoothstep(0.015, 0.14,
                min(min(local.x, 1.0 - local.x), min(local.y, 1.0 - local.y)))) * amount;
            let wave = 0.5 + 0.5 * sin((local.x + local.y) * 18.0 + u.time * 1.8);
            let offset = vec2<f32>(
                sin(local.y * 9.0 + u.time * 1.4),
                cos(local.x * 11.0 - u.time * 1.1)
            ) * (0.0025 * amount);
            let refracted = textureSample(sceneTexture, sceneSampler,
                clamp(uv + offset, vec2<f32>(0.0), vec2<f32>(1.0))).rgb;
            col = mix(col, refracted, amount * 0.28);
            col = mix(col, col * 0.72 + effect.params.rgb * 0.28, amount * 0.24);
            col = col + effect.params.rgb * (rim * 0.72 + wave * amount * 0.035);
        } else if (effect.kind == 5.0) {
            // VHS: edge chromatic aberration, faint scanlines, fine grain.
            let amount = clamp(effect.params.w, 0.0, 4.0) * inside * layerMask;
            let localEdge = abs(local.x - 0.5) * 2.0;
            let localShift = localEdge * localEdge * 1.8 * amount / u.resolution.x;
            let shifted = vec3<f32>(
                textureSample(sceneTexture, sceneSampler, uv + vec2<f32>(localShift, 0.0)).r,
                col.g,
                textureSample(sceneTexture, sceneSampler, uv - vec2<f32>(localShift, 0.0)).b
            );
            let lineScan = 1.0 - amount * 0.05 * step(2.0, (fragCoord.y - floor(fragCoord.y / 3.0) * 3.0));
            let lineNoise = fract(sin(dot(fragCoord.xy + vec2<f32>(u.time), vec2<f32>(12.9898, 78.233))) * 43758.5453);
            col = shifted * lineScan + vec3<f32>((lineNoise - 0.5) * (3.0 / 255.0) * amount);
        } else if (effect.kind == 6.0) {
            // Foil: holographic rainbow bands sliding diagonally across the subtree.
            let amount = clamp(effect.params.w, 0.0, 1.0) * inside * layerMask;
            let band = (local.x * 0.8 + local.y * 0.6) * effect.params.y + effect.params.x;
            let hue = vec3<f32>(
                0.5 + 0.5 * sin(6.2832 * band),
                0.5 + 0.5 * sin(6.2832 * (band + 0.3333)),
                0.5 + 0.5 * sin(6.2832 * (band + 0.6667))
            );
            let foil = mix(vec3<f32>(1.0), hue, clamp(effect.params.z, 0.0, 1.0));
            let luma = dot(col, vec3<f32>(0.299, 0.587, 0.114));
            col = mix(col, col * (0.55 + 0.9 * foil), amount * 0.65) + foil * amount * 0.22 * (0.35 + luma);
        } else if (effect.kind == 7.0) {
            // Lenticular: vertical lenses, each showing the image shifted by the viewing tilt.
            let amount = clamp(effect.params.w, 0.0, 1.0) * inside * layerMask;
            let stripes = max(effect.params.y, 1.0);
            let lens = fract(local.x * stripes) - 0.5;
            let shift = (effect.params.x * 0.5 + lens) * effect.params.z * 0.9 / stripes * (effect.rect.z / u.resolution.x);
            let shifted = textureSample(sceneTexture, sceneSampler,
                clamp(uv + vec2<f32>(shift, 0.0), vec2<f32>(0.0), vec2<f32>(1.0))).rgb;
            let ridge = pow(1.0 - abs(lens * 2.0), 3.0);
            let sheen = vec3<f32>(
                0.5 + 0.5 * sin(6.2832 * (effect.params.x + local.y * 0.6)),
                0.5 + 0.5 * sin(6.2832 * (effect.params.x + local.y * 0.6 + 0.3333)),
                0.5 + 0.5 * sin(6.2832 * (effect.params.x + local.y * 0.6 + 0.6667))
            );
            col = mix(col, shifted, amount * 0.7) + sheen * ridge * amount * 0.2;
        } else if (effect.kind == 9.0) {
            // Circle clip: keep only the circle inscribed in the layer's frame.
            let center = effect.rect.xy + effect.rect.zw * 0.5;
            let radius = min(effect.rect.z, effect.rect.w) * 0.5;
            let mask = 1.0 - smoothstep(-1.0, 1.0, length(fragCoord.xy - center) - radius);
            col = col * mask;
            alpha = alpha * mask;
        } else if (effect.kind == 10.0) {
            // Condition: a ripple of the picture itself, a drained look, a colour wash, a depth fog and a rim.
            // Everything is scaled by the layer's own alpha, so it never paints past what the subtree drew.
            let ripple = effect.params2.y;
            let wave = vec2<f32>(
                sin(uv.y * 24.0 + u.time * 1.7) + 0.5 * sin(uv.y * 53.0 - u.time * 2.3),
                cos(uv.x * 19.0 - u.time * 1.4) + 0.5 * cos(uv.x * 47.0 + u.time * 2.1)
            ) * (0.0011 * ripple);
            let sampled = textureSample(sceneTexture, sceneSampler, clamp(uv + wave, vec2<f32>(0.0), vec2<f32>(1.0)));
            // The layer holds premultiplied colour: grade the straight colour, then premultiply again.
            let coverage = select(1.0, sampled.a, u.composition == 1.0);
            var shade = sampled.rgb / max(coverage, 0.001);
            let luma = dot(shade, vec3<f32>(0.299, 0.587, 0.114));
            shade = mix(shade, vec3<f32>(luma), effect.params2.x * 0.85) * (1.0 - 0.28 * effect.params2.x);

            // Distance from the camera where X3D drew depth; flat UI (cleared depth) reads as infinitely far and takes no fog.
            let depthSize = textureDimensions(depthTexture);
            var fog = 0.0;
            if (depthSize.x > 1u) {
                let z = textureLoad(depthTexture, vec2<i32>(fragCoord.xy), 0);
                if (z < 0.99999) {
                    let distance = u.depthA / max(u.depthB - z, 1e-6);
                    // Behind the camera's target the picture sinks into the mist; in front of it, it stays clear.
                    fog = smoothstep(-0.2, 2.2, distance - u.depthFocus) * effect.params2.z;
                }
            }
            let tint = effect.params.rgb;
            let rim = smoothstep(0.45, 1.05, length((uv - vec2<f32>(0.5)) * vec2<f32>(1.0, 1.1)) * 1.4);
            shade = mix(shade, tint * (luma * 1.1 + 0.04), clamp(effect.params.w, 0.0, 1.0));
            shade = mix(shade, tint * (0.35 + luma), clamp(fog, 0.0, 0.92));
            // Drained pictures also sink into darkness toward the edges, which reads even over a dark picture.
            shade = shade * (1.0 - effect.params2.x * 0.6 * rim);
            shade = mix(shade, effect.params3.rgb, clamp(effect.params3.w * effect.params2.w * rim, 0.0, 1.0));
            col = shade * coverage;
            alpha = select(alpha, sampled.a, u.composition == 1.0);
        } else if (effect.kind == 8.0) {
            // Warp: a travelling sine distortion of the subtree's own pixels.
            let amount = clamp(effect.params.w, 0.0, 1.0) * inside * layerMask;
            let size = effect.rect.zw / u.resolution;
            let phase = effect.params.x * 6.2832;
            let offset = vec2<f32>(
                sin(local.y * effect.params.y + phase),
                cos(local.x * effect.params.y * 1.3 + phase)
            ) * 0.06 * size * effect.params.z * amount;
            let warped = textureSample(sceneTexture, sceneSampler,
                clamp(uv + offset, vec2<f32>(0.0), vec2<f32>(1.0)));
            col = mix(col, warped.rgb, amount);
            alpha = select(alpha, mix(alpha, warped.a, amount), u.composition == 1.0);
        }
    }

    return vec4<f32>(clamp(col, vec3<f32>(0.0), vec3<f32>(1.0)), alpha);
}
"""
