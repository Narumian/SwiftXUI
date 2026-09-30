// Texture sampling helpers. The preview and game renderer bind premultiplied
// RGBA textures; this helper intentionally extracts alpha only.

fn sampling_input_alpha(sample: vec4<f32>) -> f32 {
    return clamp(sample.a, 0.0, 1.0);
}
