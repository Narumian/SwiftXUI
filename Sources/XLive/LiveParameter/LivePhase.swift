import Foundation

/// A position in a cycle that is advanced by elapsed time instead of being derived from a
/// clock. Changing the rate (a period or a pace knob) bends the speed from that moment on
/// and never makes the position jump, which a position computed as `time / period` would.
public struct LivePhase: Equatable, Sendable, Codable {
    /// Position in the current cycle, always inside 0..<1.
    public private(set) var cycles: Double
    /// Number of completed cycles. Kept separate so waves can use stable cycle indices without
    /// losing fractional precision as the clock runs for a long time.
    public private(set) var cycleIndex: Int64

    public struct Position: Equatable, Sendable {
        public let cycleIndex: Int64
        public let fraction: Double

        init(cycleIndex: Int64, fraction: Double) {
            self.cycleIndex = cycleIndex
            self.fraction = fraction
        }
    }

    public init(cycles: Double = 0) {
        self.cycles = Self.wrapped(cycles.isFinite ? cycles : 0)
        cycleIndex = 0
    }

    private enum CodingKeys: String, CodingKey { case cycles, cycleIndex }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = try? single.decode(Double.self) {
            self.init(cycles: value)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Double.self, forKey: .cycles)
        self.init(cycles: value)
        cycleIndex = try container.decode(Int64.self, forKey: .cycleIndex)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cycles, forKey: .cycles)
        try container.encode(cycleIndex, forKey: .cycleIndex)
    }

    /// The current cycle position plus a finite LFO phase offset.
    public func position(adding offset: Double = 0) -> Position {
        guard offset.isFinite else { return Position(cycleIndex: cycleIndex, fraction: cycles) }
        let whole = offset.rounded(.down)
        let fraction = offset - whole
        let sum = cycles + fraction
        let carry: Int64 = sum >= 1 ? 1 : 0
        return Position(cycleIndex: cycleIndex &+ Self.integer(whole) &+ carry,
                        fraction: sum - Double(carry))
    }

    /// Advances by `seconds` at `cyclesPerSecond`. A non-finite or negative step, or a
    /// non-finite rate, leaves the phase where it is.
    public mutating func advance(seconds: Double, cyclesPerSecond: Double) {
        guard seconds.isFinite, seconds >= 0, cyclesPerSecond.isFinite else { return }
        let step = seconds * cyclesPerSecond
        guard step.isFinite else { return }
        let whole = step.rounded(.down)
        let fraction = step - whole
        let sum = cycles + fraction
        let carry: Int64 = sum >= 1 ? 1 : 0
        cycles = sum - Double(carry)
        cycleIndex = cycleIndex &+ Self.integer(whole) &+ carry
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

    /// Saturate only for a single unrepresentably large step; normal operation can run for
    /// billions of years before Int64 wraps, while the sub-cycle position stays precise.
    private static func integer(_ value: Double) -> Int64 {
        let bound = 9_223_372_036_854_775_808.0
        if value >= bound { return .max }
        if value <= -bound { return .min }
        return Int64(value)
    }
}
