import Foundation

public struct LiveLFO: Equatable, Sendable, Codable {
    public enum Period: Equatable, Sendable, Codable {
        case seconds(Double)
        case beats(Double)

        private enum CodingKeys: String, CodingKey { case unit, length }
        private enum Unit: String, Codable { case seconds, beats }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let length = try container.decode(Double.self, forKey: .length)
            switch try container.decode(Unit.self, forKey: .unit) {
            case .seconds: self = .seconds(length)
            case .beats: self = .beats(length)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .seconds(let length):
                try container.encode(Unit.seconds, forKey: .unit); try container.encode(length, forKey: .length)
            case .beats(let length):
                try container.encode(Unit.beats, forKey: .unit); try container.encode(length, forKey: .length)
            }
        }
    }
    public let period: Period
    /// Phase in cycles. Zero begins at the midpoint, rising.
    public let phase: Double
    public init(period: Period, phase: Double = 0) throws {
        let length: Double
        switch period { case .seconds(let value), .beats(let value): length = value }
        guard length.isFinite && length > 0, phase.isFinite else { throw LiveParameterError.invalidPeriod }
        self.period = period; self.phase = phase
    }

    private enum CodingKeys: String, CodingKey { case period, phase }

    /// Goes through the validating initializer, so a saved file cannot bring back a period
    /// or phase that `init(period:phase:)` would refuse.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(period: container.decode(Period.self, forKey: .period),
                      phase: container.decode(Double.self, forKey: .phase))
    }
}
