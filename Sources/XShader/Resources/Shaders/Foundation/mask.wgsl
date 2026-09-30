// Small deterministic mask helpers. Distances are signed: negative is inside.

fn mask_smooth_edge(distance: f32, softness: f32) -> f32 {
    let width = max(softness, 0.0001);
    return 1.0 - smoothstep(-width, width, distance);
}

fn mask_circle_sdf(uv: vec2<f32>, center: vec2<f32>, radius: f32, aspect: f32) -> f32 {
    let corrected = vec2<f32>((uv.x - center.x) * aspect, uv.y - center.y);
    return length(corrected) - radius;
}

fn mask_edge_from_sdf(distance: f32, width: f32) -> f32 {
    let edge_width = max(width, 0.0001);
    // Coverage of the original SDF plus a small exterior outline band.
    let softness = clamp(edge_width * 0.25, 0.001, 0.01);
    return mask_smooth_edge(distance - edge_width, softness);
}

// Derivative-aware coverage keeps analytic SDF edges stable across resolutions.
// This helper is intended for fragment-stage callers only.
fn mask_sdf_coverage(distance: f32) -> f32 {
    let width = max(fwidth(distance), 0.0001);
    return 1.0 - smoothstep(-width, width, distance);
}

fn mask_rounded_rect_sdf(uv: vec2<f32>, center: vec2<f32>,
                         half_extent: vec2<f32>, radius: f32,
                         aspect: f32) -> f32 {
    let safe_aspect = max(aspect, 0.0001);
    let point = vec2<f32>((uv.x - center.x) * safe_aspect, uv.y - center.y);
    let extent = vec2<f32>(max(half_extent.x, 0.0) * safe_aspect,
                           max(half_extent.y, 0.0));
    let safe_radius = clamp(radius, 0.0, min(extent.x, extent.y));
    let q = abs(point) - extent + vec2<f32>(safe_radius);
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - safe_radius;
}

fn mask_sdf_union(a: f32, b: f32) -> f32 {
    return min(a, b);
}

fn mask_sdf_intersection(a: f32, b: f32) -> f32 {
    return max(a, b);
}

// Signed-distance band helpers. `distance < 0` is inside the shape and the
// returned band is normalized to [0, 1]. Width is measured in SDF units.
// Derivatives make both bands stable when the preview resolution changes.
fn mask_sdf_inner_band(distance: f32, width: f32) -> f32 {
    let band_width = max(width, 0.0001);
    return clamp(mask_sdf_coverage(distance) -
                 mask_sdf_coverage(distance + band_width), 0.0, 1.0);
}

fn mask_sdf_outer_band(distance: f32, width: f32) -> f32 {
    let band_width = max(width, 0.0001);
    return clamp(mask_sdf_coverage(distance - band_width) -
                 mask_sdf_coverage(distance), 0.0, 1.0);
}
