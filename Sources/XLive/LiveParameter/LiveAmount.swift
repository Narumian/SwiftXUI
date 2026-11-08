import Foundation

/// The two shaping curves a modulated parameter applies to a normalised (0...1) signal.
/// Both are pure functions; nothing here holds state.
public enum LiveAmount {
    /// Maps an amount knob (0...1) to a gain. The lower half is a plain 0...1 fade; the upper
    /// half rises steeply from 1 to 100, so the knob has fine control near unity.
    public static func gain(_ amount: Double) -> Double {
        guard amount.isFinite else { return 1 }
        let amount = min(1, max(0, amount))
        return amount < 0.5 ? amount * 2 : pow((amount - 0.5) * 2, 4) * 99 + 1
    }

    /// The knob position that produces `gain`. Inverse of `gain(_:)`.
    public static func amount(forGain gain: Double) -> Double {
        guard gain.isFinite else { return 0.5 }
        let gain = min(100, max(0, gain))
        return gain < 1 ? gain / 2 : pow((gain - 1) / 99, 0.25) / 2 + 0.5
    }

    /// Scales `normal` away from `center` by the gain of `amount`. The result is not clamped:
    /// a gain above 1 can push it outside 0...1, and the value mapping clamps it afterwards.
    public static func scale(_ normal: Double, around center: Double, amount: Double) -> Double {
        (normal - center) * gain(amount) + center
    }

    /// A response curve for a 0...1 value. At 0.5 it is linear; below it lifts the value
    /// (a quick rise that levels off), above it lowers it (a slow start that steepens).
    ///
    /// `curve <= 0.5` raises the value to the power `curve * 2`; `curve > 0.5` mirrors that
    /// around the diagonal. At exactly 0 the exponent is 0, so the output is 1 for any input.
    public static func response(_ value: Double, curve: Double) -> Double {
        guard value.isFinite, curve.isFinite else { return 0 }
        let value = min(1, max(0, value)), curve = min(1, max(0, curve))
        if curve <= 0.5 { return pow(value, curve * 2) }
        return 1 - pow(1 - value, (1 - curve) * 2)
    }
}
