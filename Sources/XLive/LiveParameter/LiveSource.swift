import Foundation
import XCombine

/// What a parameter listens to, as data: it can be saved, and the host decides how to
/// satisfy it. A parameter never reaches for a global audio, motion or MIDI service.
public enum LiveSourceDescriptor: Equatable, Hashable, Sendable, Codable {
    case audio(LiveAudioBand)
    case motion(LiveMotionAxis)
    /// Any MIDI input source; channel is zero-based, 0...15.
    case midiControl(channel: UInt8, controller: UInt8)
    case midiNote(channel: UInt8, note: UInt8)
    case gamepad(id: String)
    /// Another parameter in the same session, by its stable identity.
    case parameter(LiveObjectID)

    /// The value that scaling by amount leaves in place for this source. Audio rests at 0
    /// (silence), everything else at the middle.
    public var amountCenter: Double {
        if case .audio = self { return 0 }
        return 0.5
    }
}

/// The host's side of the boundary. It returns a stream of normalised (0...1) values for a
/// source, or nil when it cannot provide that source (a missing device, a denied permission).
/// A parameter treats nil as "no signal", not as an error.
///
/// Values are delivered on the thread or actor that owns the graph. A source that produces on
/// another thread hops over first, for instance through `XInbox`.
public protocol LiveSourceProvider {
    func publisher(for source: LiveSourceDescriptor) -> XAnyPublisher<Double, Never>?
}
