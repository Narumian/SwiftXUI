// Gradient helpers return an unclamped interpolation coordinate. Callers pick
// a clamp/repeat policy explicitly; the initial static assets use clamp.

fn gradient_linear_t(uv: vec2<f32>, start: vec2<f32>, end: vec2<f32>) -> f32 {
    let axis = end - start;
    return dot(uv - start, axis) / max(dot(axis, axis), 0.0001);
}

fn gradient_radial_t(uv: vec2<f32>, center: vec2<f32>, radius: f32, content_aspect: f32) -> f32 {
    let point = uv_aspect_correct(uv - center + vec2<f32>(0.5), content_aspect);
    return length(point) / max(radius, 0.0001);
}
