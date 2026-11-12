import Foundation

/// What a MIDI control does to a parameter whose value it did not set last.
public enum LiveTakeoverMode: String, Equatable, Sendable, Codable {
    /// The control is ignored until it reaches the value, so the value never jumps.
    case pickup
    /// The value jumps to where the control is.
    case jump
}

/// The runtime half of pickup for one parameter: whether a control holds the value, and where it
/// last was. It is a plain value with no clock and no subscriptions, and it is not saved.
///
/// A control holds the value once it sets it. Anything else that writes the value (a hand, a
/// reset, automation, a new range) calls `release()`, and the control must then come back to the
/// value before it holds it again: either land within `tolerance` of it, or move across it
/// between two messages. Positions are in the parameter's own 0...1 space, after the response
/// curve, so they compare directly with `LiveValueMapping.normalized`.
public struct LiveTakeover: Equatable, Sendable {
    /// Closest a control may be to the value, in positions, to count as being on it: one step of
    /// a 7-bit control.
    public static let tolerance = 1.0 / 127

    /// The control that holds the value, or nil when something else wrote it last.
    public private(set) var engaged: LiveMIDIAddress?
    /// Where the control last was, whether or not it held the value. Nil before the first message.
    public private(set) var position: Double?
    private var positionAddress: LiveMIDIAddress?

    public init() {}

    /// Records the control's new position and says whether it may set the value now. A control
    /// that already holds the value always may; another one must be on the value or have crossed it.
    /// The caller writes the value and then calls `engage(_:)`.
    public mutating func accepts(_ newPosition: Double, from address: LiveMIDIAddress, current: Double,
                                 tolerance: Double = LiveTakeover.tolerance) -> Bool {
        let previous = positionAddress == address ? position : nil
        position = newPosition; positionAddress = address
        if engaged == address { return true }
        if abs(newPosition - current) <= tolerance { return true }
        guard let previous else { return false }
        return (previous - current) * (newPosition - current) <= 0
    }

    /// The control now holds the value. Call it after writing the value, which releases it.
    public mutating func engage(_ address: LiveMIDIAddress) { engaged = address }

    /// The value was written by something other than the control.
    public mutating func release() { engaged = nil }
}
