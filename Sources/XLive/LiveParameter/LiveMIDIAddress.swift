import Foundation

/// Which MIDI control a parameter follows: a controller (CC) or a note, on one channel.
/// It matches any input source; choosing a device is the host's concern.
public struct LiveMIDIAddress: Equatable, Hashable, Sendable, Codable {
    public enum Kind: String, Equatable, Hashable, Sendable, Codable { case control, note }

    public let kind: Kind
    /// Zero-based, 0...15.
    public let channel: UInt8
    /// Controller number or note number, 0...127.
    public let number: UInt8

    public init(kind: Kind, channel: UInt8, number: UInt8) throws {
        guard channel <= 15, number <= 127 else { throw LiveParameterError.invalidAddress }
        self.kind = kind; self.channel = channel; self.number = number
    }

    private enum CodingKeys: String, CodingKey { case kind, channel, number }

    /// Goes through the validating initializer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: container.decode(Kind.self, forKey: .kind),
                      channel: container.decode(UInt8.self, forKey: .channel),
                      number: container.decode(UInt8.self, forKey: .number))
    }

    /// The address a message would be learned as. A note-off is not learnable: it usually
    /// arrives as the release of a key pressed before learning began.
    public init?(learning message: MIDIMessage) {
        switch message {
        case .controlChange(let channel, let controller, _):
            guard channel <= 15, controller <= 127 else { return nil }
            self.kind = .control; self.channel = channel; self.number = controller
        case .noteOn(let channel, let note, let velocity):
            guard velocity > 0, channel <= 15, note <= 127 else { return nil }
            self.kind = .note; self.channel = channel; self.number = note
        case .noteOff:
            return nil
        }
    }

    /// The address a message belongs to, for routing it to the parameters that follow that
    /// control. Unlike `init?(learning:)` this includes note-offs and zero-velocity note-ons,
    /// which a note address follows (as 0).
    public init?(routing message: MIDIMessage) {
        switch message {
        case .controlChange(let channel, let controller, _):
            guard channel <= 15, controller <= 127 else { return nil }
            self.kind = .control; self.channel = channel; self.number = controller
        case .noteOn(let channel, let note, _), .noteOff(let channel, let note, _):
            guard channel <= 15, note <= 127 else { return nil }
            self.kind = .note; self.channel = channel; self.number = note
        }
    }

    /// The 7-bit value this message carries for this address, or nil if it is for another
    /// control. A note-on carries its velocity and a note-off carries 0.
    public func value(in message: MIDIMessage) -> UInt8? {
        switch (kind, message) {
        case (.control, .controlChange(let ch, let controller, let value)) where ch == channel && controller == number:
            return min(127, value)
        case (.note, .noteOn(let ch, let note, let velocity)) where ch == channel && note == number:
            return min(127, velocity)
        case (.note, .noteOff(let ch, let note, _)) where ch == channel && note == number:
            return 0
        default:
            return nil
        }
    }

    public var descriptor: LiveSourceDescriptor {
        switch kind {
        case .control: return .midiControl(channel: channel, controller: number)
        case .note: return .midiNote(channel: channel, note: number)
        }
    }
}
