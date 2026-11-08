import Foundation

/// A position in a cycle that is advanced by elapsed time instead of being derived from a
/// clock. Changing the rate (a period or a pace knob) bends the speed from that moment on
/// and never makes the position jump, which a position computed as `time / period` would.
public struct LivePhase: Equatable, Sendable, Codable {
    /// Position in the current cycle, always inside 0..<1.
    public private(set) var cycles: Double

    public init(cycles: Double = 0) {
        self.cycles = Self.wrapped(cycles.isFinite ? cycles : 0)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(cycles: try container.decode(Double.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(cycles)
    }

    /// Advances by `seconds` at `cyclesPerSecond`. A non-finite or negative step, or a
    /// non-finite rate, leaves the phase where it is.
    public mutating func advance(seconds: Double, cyclesPerSecond: Double) {
        guard seconds.isFinite, seconds >= 0, cyclesPerSecond.isFinite else { return }
        let step = seconds * cyclesPerSecond
        guard step.isFinite else { return }
        cycles = Self.wrapped(cycles + step.truncatingRemainder(dividingBy: 1))
    }

    /// Advances for one cycle length `period`, multiplied by `pace`.
    /// A beat period needs `bpm`; without a usable tempo the phase holds.
    public mutating func advance(seconds: Double, period: LiveLFO.Period, bpm: Double?, pace: Double = 1) {
        guard pace.isFinite else { return }
        switch period {
        case .seconds(let length):
            advance(seconds: seconds, cyclesPerSecond: pace / length)
        case .beats(let length):
            guard let bpm, bpm.isFinite, bpm > 0 else { return }
            advance(seconds: seconds, cyclesPerSecond: bpm / 60 / length * pace)
        }
    }

    private static func wrapped(_ value: Double) -> Double {
        let r = value - value.rounded(.down)
        return r < 1 ? r : 0   // r can round up to exactly 1 for tiny negative inputs
    }
}
