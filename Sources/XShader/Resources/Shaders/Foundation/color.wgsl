// Shared color helpers. All inputs and outputs are linear sRGB unless a
// function explicitly says otherwise.

fn saturate(value: f32) -> f32 {
    return clamp(value, 0.0, 1.0);
}

fn color_luminance(color: vec3<f32>) -> f32 {
    return dot(color, vec3<f32>(0.2126, 0.7152, 0.0722));
}

fn color_mix_linear(a: vec3<f32>, b: vec3<f32>, t: f32) -> vec3<f32> {
    return mix(a, b, saturate(t));
}

fn color_adjust_saturation(color: vec3<f32>, amount: f32) -> vec3<f32> {
    return mix(vec3<f32>(color_luminance(color)), color, max(amount, 0.0));
}

fn color_adjust_contrast(color: vec3<f32>, amount: f32) -> vec3<f32> {
    return (color - vec3<f32>(0.5)) * max(amount, 0.0) + vec3<f32>(0.5);
}

fn color_linear_to_srgb_channel(value: f32) -> f32 {
    let safe = max(value, 0.0);
    if (safe <= 0.0031308) {
        return safe * 12.92;
    }
    return 1.055 * pow(safe, 1.0 / 2.4) - 0.055;
}

fn color_linear_to_srgb(color: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(
        color_linear_to_srgb_channel(color.r),
        color_linear_to_srgb_channel(color.g),
        color_linear_to_srgb_channel(color.b)
    );
}

// Presentation targets that are not sRGB views need an explicit encode. Keep
// the result premultiplied so the preview pipeline can use One / OneMinusSrcAlpha.
fn color_premultiplied_linear_to_srgb(color: vec3<f32>, alpha: f32) -> vec3<f32> {
    let safe_alpha = max(alpha, 0.00001);
    let straight = clamp(color / safe_alpha, vec3<f32>(0.0), vec3<f32>(1.0));
    return color_linear_to_srgb(straight) * saturate(alpha);
}
