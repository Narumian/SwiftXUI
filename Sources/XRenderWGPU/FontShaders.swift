/// SDF font pipeline. The dynamic atlas stores signed distance in red, while
/// alpha remains conventional coverage for CPU/export tooling. One fragment
/// evaluation emits both a smooth outline and fill, replacing the former ring
/// of twelve shifted text draws.
let fontWGSL = """
struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) fill: vec4<f32>,
    @location(2) outline: vec4<f32>,
    // Requested in framebuffer pixels, not atlas pixels. This makes the
    // stroke responsive to both layout and device scale.
    @location(3) outlinePixels: f32,
    // Atlas-pixel reach of this atlas's distance field (see FontAtlas.sdfRange).
    @location(4) sdfRange: f32,
};

@group(0) @binding(0) var fontTexture: texture_2d<f32>;
@group(0) @binding(1) var fontSampler: sampler;

@vertex
fn vs_main(
    @location(0) position: vec2<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) fill: vec4<f32>,
    @location(3) outline: vec4<f32>,
    @location(4) outlinePixels: f32,
    @location(5) sdfRange: f32
) -> VertexOut {
    var out: VertexOut;
    out.position = vec4<f32>(position, 0.0, 1.0);
    out.uv = uv;
    out.fill = fill;
    out.outline = outline;
    out.outlinePixels = outlinePixels;
    out.sdfRange = sdfRange;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    // Positive distance is glyph interior, in atlas pixels; the red channel
    // encodes 128 + d / range * 127, so 0.5 is the contour.
    let sampled = textureSample(fontTexture, fontSampler, in.uv);
    let distance = (sampled.r - 0.5) * 2.0 * in.sdfRange;
    // `aa` = atlas pixels per framebuffer pixel: a native-size atlas drawn 1:1
    // gives 1, a minified one gives more. Derivatives keep the transition one
    // framebuffer pixel wide under any scaling.
    // Measured on the uv, which is affine across the glyph, so it is the same
    // for every fragment. `fwidth(distance)` is not: it is one value per 2x2
    // quad and |dx|+|dy| overstates a diagonal edge by up to 41%, which made a
    // wide stroke bumpy (2px blocks) and thicker on diagonals.
    let atlasSize = vec2<f32>(textureDimensions(fontTexture));
    let texels = in.uv * atlasSize;
    let aa = max((length(dpdx(texels)) + length(dpdy(texels))) * 0.5, 0.0001);;
    // `aa` is SDF units per framebuffer pixel. Converting at the fragment
    // preserves the authored stroke width through responsive reflow, Retina
    // scale, and any view transform.
    let outlineWidth = in.outlinePixels * aa;
    let outer = clamp((distance + outlineWidth) / aa + 0.5, 0.0, 1.0);
    // Preserve CoreText's original coverage for the fill. The SDF is only for
    // the contour; using it for both made the body of small glyphs stair-step.
    let fillCoverage = sampled.a;
    let fillAlpha = fillCoverage * in.fill.a;
    let outlineAlpha = outer * in.outline.a;
    // Both colors arrive premultiplied. Place the fill over its outline so a
    // translucent label behaves exactly like normal sprite compositing.
    let rgb = in.fill.rgb * fillCoverage + in.outline.rgb * outer * (1.0 - fillAlpha);
    let alpha = fillAlpha + outlineAlpha * (1.0 - fillAlpha);
    return vec4<f32>(rgb, alpha);
}
"""
