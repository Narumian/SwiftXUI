// Small deterministic math helpers. Inputs are finite authoring values; the
// guards keep malformed ranges from creating a divide-by-zero in a shader.

fn math_safe_divide(numerator: f32, denominator: f32) -> f32 {
    if (abs(denominator) <= 0.0001) {
        return 0.0;
    }
    return numerator / denominator;
}

fn math_remap_clamped(value: f32, input_min: f32, input_max: f32,
                      output_min: f32, output_max: f32) -> f32 {
    let input_span = input_max - input_min;
    if (abs(input_span) <= 0.0001) {
        return output_min;
    }
    let t = clamp((value - input_min) / input_span, 0.0, 1.0);
    return mix(output_min, output_max, t);
}
