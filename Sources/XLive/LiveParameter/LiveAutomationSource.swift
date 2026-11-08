import Foundation

/// What drives a parameter while its automation is on.
public enum LiveAutomationSource: Equatable, Hashable, Sendable, Codable {
    /// The parameter's own wave, advanced by the clock.
    case lfo
    case audio(LiveAudioBand)
    case motion(LiveMotionAxis)
    case gamepad(id: String)

    /// What the host must supply for this source, or nil when the parameter makes it itself.
    public var descriptor: LiveSourceDescriptor? {
        switch self {
        case .lfo: return nil
        case .audio(let band): return .audio(band)
        case .motion(let axis): return .motion(axis)
        case .gamepad(let id): return .gamepad(id: id)
        }
    }

    /// The value that scaling by the amount leaves in place (see `LiveAmount.scale`).
    public var amountCenter: Double { descriptor?.amountCenter ?? 0.5 }
}

/// What the host gives a parameter on each clock step. The parameter reads nothing else:
/// no global tempo, audio, motion or other parameter.
public struct LiveTick: Sendable {
    /// Seconds since the previous step.
    public var deltaTime: Double
    /// Current tempo, for a beat-length LFO. Nil holds the LFO still.
    public var bpm: Double?
    /// Speed multiplier for the LFO, the value of the parameter named by `paceReference`.
    public var pace: Double
    /// Pulse width for a `.pwm` wave, the value of the parameter named by `pulseWidthReference`.
    public var pulseWidth: Double?
    /// The latest value of the active audio, motion or gamepad source, normalised to 0...1.
    /// Nil means there is no signal yet, and the parameter holds.
    public var sourceValue: Double?

    public init(deltaTime: Double, bpm: Double? = nil, pace: Double = 1, pulseWidth: Double? = nil, sourceValue: Double? = nil) {
        self.deltaTime = deltaTime; self.bpm = bpm; self.pace = pace
        self.pulseWidth = pulseWidth; self.sourceValue = sourceValue
    }
}

/// What a MIDI message did to a parameter.
public enum LiveMIDIReception: Equatable, Sendable {
    /// The message was not for this parameter.
    case ignored
    /// Learning was on and the message's control was bound. The value is unchanged.
    case learned(LiveMIDIAddress)
    /// The message set the value to this.
    case applied(Double)
}

public enum LiveMIDIState: Equatable, Sendable { case none, assigned, learning }

public enum LiveValueFormat {
    /// The value as the slider label shows it: five decimals cut to seven characters, or a
    /// whole number from 100000 up.
    public static func text(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value >= 100_000 { return value < 9e18 ? String(Int64(value)) : "—" }
        // Digits by integer arithmetic: `String(format:)` costs about a microsecond, which adds
        // up when hundreds of labels redraw every frame. Values that sit within rounding error of
        // a tie go the slow way, so the result is always what `%.5f` would give.
        let scaled = abs(value) * 100_000
        let fraction = scaled - scaled.rounded(.down)
        guard abs(fraction - 0.5) > 1e-6 else { return String(String(format: "%.5f", value).prefix(7)) }
        let units = UInt64(scaled.rounded())
        let whole = units / 100_000, decimals = units % 100_000
        var text = value.sign == .minus ? "-" : ""
        text += String(whole)
        text += "."
        let digits = String(decimals)
        text += String(repeating: "0", count: 5 - digits.count)
        text += digits
        return String(text.prefix(7))
    }
}
