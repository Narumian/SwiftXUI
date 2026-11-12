import Foundation
import XCombine

/// A ready-made `LiveParameterEnvironment` for an app that already runs a frame loop.
///
/// The app calls `advance(seconds:)` once per frame, from the thread or actor that owns its UI,
/// and that is the parameters' clock: nothing here runs a timer. MIDI messages are pushed in
/// with `send(_:)`, and a source (audio, motion, gamepad) is offered with `provide(_:_:)`.
/// Parameters made through `add(_:)` are kept here, so they can find each other by id.
///
/// Like everything built on XCombine it belongs to one thread or actor.
public final class LiveParameterHost: LiveParameterEnvironment {
    private let clockSubject = XPassthroughSubject<LiveClockTick, Never>()
    private let midiSubject = XPassthroughSubject<MIDIMessage, Never>()
    private var routes: [LiveMIDIAddress: XPassthroughSubject<MIDIMessage, Never>] = [:]
    private var registry: [LiveObjectID: LiveParameter] = [:]
    private var sources: [LiveSourceDescriptor: XAnyPublisher<Double, Never>] = [:]

    /// The tempo that beat-length LFOs follow; nil holds them.
    public var bpm: Double?
    /// What a MIDI control does to a parameter it does not hold; see `LiveTakeoverMode`.
    public var midiTakeover: LiveTakeoverMode = .pickup

    public init(bpm: Double? = nil) { self.bpm = bpm }

    public var clock: XAnyPublisher<LiveClockTick, Never> { clockSubject.eraseToAnyPublisher() }
    public var midi: XAnyPublisher<MIDIMessage, Never> { midiSubject.eraseToAnyPublisher() }
    public func midi(for address: LiveMIDIAddress) -> XAnyPublisher<MIDIMessage, Never>? {
        if let route = routes[address] { return route.eraseToAnyPublisher() }
        let route = XPassthroughSubject<MIDIMessage, Never>()
        routes[address] = route
        return route.eraseToAnyPublisher()
    }
    public func publisher(for source: LiveSourceDescriptor) -> XAnyPublisher<Double, Never>? { sources[source] }
    public func parameter(withID id: LiveObjectID) -> LiveParameter? { registry[id] }

    /// Makes a parameter that listens to this host, and keeps it. A second parameter with the
    /// same id replaces the first.
    @discardableResult
    public func add(_ state: LiveParameterState) -> LiveParameter {
        let parameter = LiveParameter(state: state, environment: self)
        registry[parameter.id] = parameter
        return parameter
    }

    public func remove(_ id: LiveObjectID) { registry[id] = nil }
    public var parameters: [LiveParameter] { Array(registry.values) }

    /// Offers the normalised values of a source. Offer it before a parameter that uses it turns
    /// automation on; a parameter that is already listening does not look again.
    public func provide(_ source: LiveSourceDescriptor, _ values: XAnyPublisher<Double, Never>?) {
        sources[source] = values
    }

    /// One frame. A negative or non-finite step does nothing.
    public func advance(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        clockSubject.send(LiveClockTick(deltaTime: seconds, bpm: bpm))
    }

    /// A MIDI message from the app's input. It goes first to the parameters that follow its
    /// control, then to whoever listens to everything (a parameter learning an address). In
    /// that order, so a parameter that learns this very message does not also apply it.
    public func send(_ message: MIDIMessage) {
        if let address = LiveMIDIAddress(routing: message) { routes[address]?.send(message) }
        midiSubject.send(message)
    }
}
