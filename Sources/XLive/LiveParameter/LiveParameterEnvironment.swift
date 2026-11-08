import Foundation
import XCombine

/// Everything a parameter listens to, supplied by the host. It replaces the global services a
/// parameter would otherwise reach for (a shared timer, the audio input, the motion sensors, the
/// MIDI manager, a tempo, other parameters). Only `clock` is required.
///
/// Publishers deliver on the thread or actor that owns the graph. A source that produces on
/// another thread hops over first (see `XInbox`).
public protocol LiveParameterEnvironment: AnyObject {
    /// The clock. A parameter subscribes only while it needs time, so a clock backed by an
    /// `XTimer` runs only while something is automated.
    var clock: XAnyPublisher<LiveClockTick, Never> { get }
    /// Every MIDI message that arrives. A parameter listens to it only while it is learning an address, or when `midi(for:)` is not available.
    var midi: XAnyPublisher<MIDIMessage, Never> { get }
    /// The messages for one control only. A host that can route by address answers here, so a
    /// message reaches just the parameters that follow it instead of every parameter; nil means
    /// the host cannot, and the parameter filters `midi` itself.
    func midi(for address: LiveMIDIAddress) -> XAnyPublisher<MIDIMessage, Never>?
    /// The normalised (0...1) values of an audio, motion or gamepad source, or nil if the host
    /// cannot provide it. A parameter treats nil as "no signal".
    func publisher(for source: LiveSourceDescriptor) -> XAnyPublisher<Double, Never>?
    /// Another parameter, for the references that set LFO pace and pulse width.
    func parameter(withID id: LiveObjectID) -> LiveParameter?
}

public extension LiveParameterEnvironment {
    var midi: XAnyPublisher<MIDIMessage, Never> {
        XPublishers.Empty<MIDIMessage, Never>(completeImmediately: false).eraseToAnyPublisher()
    }
    func midi(for address: LiveMIDIAddress) -> XAnyPublisher<MIDIMessage, Never>? { nil }
    func publisher(for source: LiveSourceDescriptor) -> XAnyPublisher<Double, Never>? { nil }
    func parameter(withID id: LiveObjectID) -> LiveParameter? { nil }
}
