import Foundation

/// The simple MIDI parameter: a bounded value that follows one MIDI control and can also be
/// set by hand. There is no clock and no `update`; the value changes only when a message
/// arrives (`receive`) or a manual value is set.
///
/// Whichever of the two wrote last wins, and a MIDI message makes the value jump to where the
/// control is. There is no pickup, so a knob that is far from the slider will move it at once.
///
/// Its sibling `LiveParameterLFOSimple` is driven by time instead.
public struct LiveParameterMIDISimple: Sendable, Codable {
    /// Who set the current value last.
    public enum Origin: String, Equatable, Sendable, Codable { case initial, manual, midi }

    /// What `receive(_:)` did with a message.
    public typealias Reception = LiveMIDIReception

    public let mapping: LiveValueMapping
    /// Response curve for the incoming 0...1 position; 0.5 is linear (see `LiveAmount.response`).
    public let curve: Double
    public private(set) var value: Double
    public private(set) var address: LiveMIDIAddress?
    public private(set) var isLearning = false
    public private(set) var origin: Origin = .initial

    public var range: ClosedRange<Double> { mapping.range }
    public var normalizedValue: Double { mapping.normalized(value) }

    public init(value: Double, mapping: LiveValueMapping? = nil, address: LiveMIDIAddress? = nil, curve: Double = 0.5) throws {
        let mapping = try mapping ?? LiveValueMapping()
        guard let constrained = mapping.constrained(value) else { throw LiveParameterError.invalidValue }
        guard curve.isFinite else { throw LiveParameterError.invalidValue }
        self.mapping = mapping
        self.value = constrained
        self.address = address
        self.curve = min(1, max(0, curve))
    }

    private enum CodingKeys: String, CodingKey { case value, mapping, address, curve, origin }

    /// Restores through the validating initializer. Learning is never saved: a session that
    /// reopens does not wait for a message. The origin is limited to what it could have been.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(value: container.decode(Double.self, forKey: .value),
                      mapping: container.decode(LiveValueMapping.self, forKey: .mapping),
                      address: container.decodeIfPresent(LiveMIDIAddress.self, forKey: .address),
                      curve: container.decodeIfPresent(Double.self, forKey: .curve) ?? 0.5)
        origin = try container.decodeIfPresent(Origin.self, forKey: .origin) ?? .initial
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(mapping, forKey: .mapping)
        try container.encodeIfPresent(address, forKey: .address)
        try container.encode(curve, forKey: .curve)
        try container.encode(origin, forKey: .origin)
    }

    // MARK: Manual

    /// Sets the value by hand. Snapped to the step and clamped; a non-finite value is ignored.
    public mutating func setManualValue(_ newValue: Double) {
        guard let constrained = mapping.constrained(newValue) else { return }
        value = constrained; origin = .manual
    }

    public mutating func setNormalizedManualValue(_ normalized: Double) {
        guard let constrained = mapping.value(forNormal: normalized) else { return }
        value = constrained; origin = .manual
    }

    // MARK: MIDI

    /// Starts waiting for the next learnable message to bind to.
    public mutating func beginLearning() { isLearning = true }
    public mutating func cancelLearning() { isLearning = false }

    /// Follows `address`, or nothing when nil. Ends any learning in progress.
    public mutating func bind(_ address: LiveMIDIAddress?) {
        self.address = address; isLearning = false
    }

    /// Feeds one message. While learning, the first learnable message becomes the address and
    /// is not applied. Otherwise a message for the bound address sets the value.
    @discardableResult
    public mutating func receive(_ message: MIDIMessage) -> Reception {
        if isLearning {
            guard let learned = LiveMIDIAddress(learning: message) else { return .ignored }
            address = learned; isLearning = false
            return .learned(learned)
        }
        guard let address, let raw = address.value(in: message) else { return .ignored }
        let position = LiveAmount.response(Double(raw) / 127, curve: curve)
        guard let constrained = mapping.value(forNormal: position) else { return .ignored }
        value = constrained; origin = .midi
        return .applied(constrained)
    }
}
