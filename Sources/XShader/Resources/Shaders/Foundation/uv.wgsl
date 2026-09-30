// Normalized UV helpers. UV origin is top-left; v increases downward.

fn uv_aspect_correct(uv: vec2<f32>, content_aspect: f32) -> vec2<f32> {
    let centered = uv - vec2<f32>(0.5);
    return vec2<f32>(centered.x * max(content_aspect, 0.0001), centered.y);
}

fn uv_scale_centered(uv: vec2<f32>, scale: vec2<f32>, center: vec2<f32>) -> vec2<f32> {
    return center + (uv - center) * scale;
}

fn uv_offset(uv: vec2<f32>, offset: vec2<f32>) -> vec2<f32> {
    return uv + offset;
}

fn uv_rotate_centered(uv: vec2<f32>, radians: f32, center: vec2<f32>) -> vec2<f32> {
    let c = cos(radians);
    let s = sin(radians);
    let offset_from_center = uv - center;
    return center + vec2<f32>(offset_from_center.x * c - offset_from_center.y * s,
                              offset_from_center.x * s + offset_from_center.y * c);
}
