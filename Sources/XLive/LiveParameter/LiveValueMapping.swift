import Foundation

/// How a normalised (0...1) position becomes a value, and back: a visible range, an optional
/// hard limit, and an optional step. Inversion is not here — it belongs to the automation
/// stage, which flips a source's output, not to the slider.
public struct LiveValueMapping: Equatable, Sendable, Codable {
    /// The range the slider spans.
    public let range: ClosedRange<Double>
    /// A hard clamp applied after the range. Must overlap `range`.
    public let limit: ClosedRange<Double>?
    /// Spacing of allowed values, counted from `range.lowerBound`.
    public let step: Double?

    public init(range: ClosedRange<Double> = 0...1, limit: ClosedRange<Double>? = nil, step: Double? = nil) throws {
        guard range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound < range.upperBound,
              (range.upperBound - range.lowerBound).isFinite else { throw LiveParameterError.invalidRange }
        if let limit {
            guard limit.lowerBound.isFinite, limit.upperBound.isFinite,
                  limit.lowerBound <= range.upperBound, limit.upperBound >= range.lowerBound
            else { throw LiveParameterError.invalidRange }
        }
        if let step { guard step.isFinite, step > 0 else { throw LiveParameterError.invalidValue } }
        self.range = range; self.limit = limit; self.step = step
    }

    private enum CodingKeys: String, CodingKey { case range, limit, step }

    /// Goes through the validating initializer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(range: container.decode(ClosedRange<Double>.self, forKey: .range),
                      limit: container.decodeIfPresent(ClosedRange<Double>.self, forKey: .limit),
                      step: container.decodeIfPresent(Double.self, forKey: .step))
    }

    /// The range the value can actually reach: `range` narrowed by `limit`.
    public var reachable: ClosedRange<Double> {
        guard let limit else { return range }
        return max(range.lowerBound, limit.lowerBound)...min(range.upperBound, limit.upperBound)
    }

    /// Position of `value` in the range. Not clamped: a value outside gives below 0 or above 1.
    public func normalized(_ value: Double) -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    /// The value for a position, snapped to `step` and clamped to the reachable range.
    /// Returns nil for a non-finite position.
    public func value(forNormal normal: Double) -> Double? {
        guard normal.isFinite else { return nil }
        return constrained(range.lowerBound + normal * (range.upperBound - range.lowerBound))
    }

    /// Snaps `value` to `step` and clamps it to the reachable range. Nil if not finite.
    public func constrained(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        var result = value
        if let step { result = range.lowerBound + ((result - range.lowerBound) / step).rounded() * step }
        let bounds = reachable
        return min(bounds.upperBound, max(bounds.lowerBound, result))
    }
}
