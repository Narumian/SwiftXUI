// Coordinate-only noise. The caller supplies a seed; time is deliberately not
// part of this API, so a static asset remains reproducible.

fn noise_hash_2d(cell: vec2<f32>, seed: f32) -> f32 {
    let value = dot(cell, vec2<f32>(127.1, 311.7)) + seed * 74.7;
    return fract(sin(value) * 43758.5453);
}

fn surface_grain(uv: vec2<f32>, cells_per_unit: f32, seed: f32) -> f32 {
    let cells = max(cells_per_unit, 1.0);
    return noise_hash_2d(floor(uv * cells), seed);
}
