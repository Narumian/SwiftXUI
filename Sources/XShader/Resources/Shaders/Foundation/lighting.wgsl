// Stylized 2D lighting. It intentionally has no time or scene dependency.

fn lighting_fake_bevel(distance: f32, uv: vec2<f32>, width: f32, strength: f32) -> vec3<f32> {
    let bevel_width = max(width, 0.0001);
    let band = 1.0 - smoothstep(0.0, bevel_width, abs(distance));
    let light_direction = normalize(vec2<f32>(-0.6, -0.8));
    let radial = uv;
    let radial_direction = radial / max(length(radial), 0.0001);
    let directional = saturate(dot(radial_direction, light_direction));
    let highlight = band * directional * max(strength, 0.0);
    return vec3<f32>(highlight);
}

// A symmetric edge reflection for static stylized surfaces; it has no scene
// light or time input and therefore stays useful to multiple asset families.
fn lighting_rim_from_uv(uv: vec2<f32>, width: f32, strength: f32) -> f32 {
    let edge_distance = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
    let edge_width = max(width, 0.0001);
    return (1.0 - smoothstep(0.0, edge_width, edge_distance)) * max(strength, 0.0);
}

// A static coordinate-space highlight shared by surfaces with a broad band.
fn lighting_highlight_band(coordinate: f32, center: f32, width: f32) -> f32 {
    let band_width = max(width, 0.0001);
    return 1.0 - smoothstep(0.0, band_width, abs(coordinate - center));
}
