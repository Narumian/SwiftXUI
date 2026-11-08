import Foundation
import XCombine

/// A parameter that runs itself. It owns a `LiveParameterState` and, from a
/// `LiveParameterEnvironment`, subscribes to what that state needs:
///
/// - the clock, only while the state needs time (automation on, a reset gliding, smoothing
///   catching up);
/// - the automation source's values, only while automation is on, and re-subscribed when the
///   source changes;
/// - MIDI, only for the addresses it follows (through the host's per-address route when it
///   has one) and, while learning, the whole stream.
///
/// Nobody calls it each frame. Read `value` or subscribe to `valuePublisher`; change it with
/// the setters or `edit`. It is a reference type because a slider, a MIDI mapping and other
/// parameters (through `parameter(withID:)`) share one parameter.
///
/// Like all of XCombine it belongs to one thread or actor: create it, change it and cancel it
/// there. The environment is held weakly, so a registry that holds parameters does not form a cycle.
public final class LiveParameter: Identifiable, @unchecked Sendable {
    public private(set) var state: LiveParameterState {
        didSet { if !ticking { stateDidChange() } }
    }
    /// Copies of the few facts read on every MIDI message and clock step (what `reacts(to:)` looks
    /// at, and the two references), so the common answer does not copy the whole state. Kept
    /// current by `stateDidChange`; a clock step cannot change them.
    private var midiLearning = false
    private var midiAutomated = false
    private var midiAddresses: [LiveMIDIAddress] = []
    private var paceID: LiveObjectID?
    private var pulseWidthID: LiveObjectID?
    /// True while the clock step changes `state` in place: that path does its own, lighter upkeep.
    private var ticking = false
    private let valueSubject: XCurrentValueSubject<Double, Never>
    public private(set) weak var environment: (any LiveParameterEnvironment)?

    private var clockToken: XAnyCancellable?
    private var sourceToken: XAnyCancellable?
    /// The whole MIDI stream: only while learning, or for a host that cannot route by address.
    private var allMIDIToken: XAnyCancellable?
    /// One subscription per followed address, when the host routes.
    private var addressTokens: [XAnyCancellable] = []
    private var routedAddresses: [LiveMIDIAddress]?
    private var needsAllMIDI = false
    private var subscribedSource: LiveSourceDescriptor?
    private var latestSourceValue: Double?

    private struct WeakReference { weak var parameter: LiveParameter?; var id: LiveObjectID }
    private var paceTarget: WeakReference?
    private var pulseWidthTarget: WeakReference?

    public init(state: LiveParameterState, environment: (any LiveParameterEnvironment)? = nil) {
        self.state = state
        valueSubject = XCurrentValueSubject(state.value)
        refreshMIDIFilter()
        if let environment { attach(to: environment) }
    }

    /// The subscriptions capture `self` without counting it (a weak reference makes every call
    /// slower, and a clock step runs for each parameter every frame), so they must be cancelled
    /// before the object goes. Everything is confined to one thread, so nothing can fire in between.
    deinit { clockToken = nil; sourceToken = nil; dropMIDI() }

    public var id: LiveObjectID { state.id }
    public var value: Double { state.value }
    /// The current value now, then every change.
    public var valuePublisher: XAnyPublisher<Double, Never> { valueSubject.eraseToAnyPublisher() }

    /// Connects the parameter to a host. Anything it was listening to before is dropped.
    public func attach(to environment: any LiveParameterEnvironment) {
        clockToken = nil; sourceToken = nil; dropMIDI()
        subscribedSource = nil; latestSourceValue = nil; paceTarget = nil; pulseWidthTarget = nil
        self.environment = environment
        reconcile()
    }

    /// Changes the state. Everything else (`setManualValue`, `toggleAutomation`, …) is a shortcut for this.
    public func edit(_ change: (inout LiveParameterState) -> Void) {
        var next = state
        change(&next)
        state = next
    }

    // MARK: Shortcuts a slider uses

    public func setManualValue(_ newValue: Double) { edit { $0.setManualValue(newValue) } }
    public func setNormalizedManualValue(_ normalized: Double) { edit { $0.setNormalizedManualValue(normalized) } }
    public func toggleAutomation() { edit { $0.toggleAutomation() } }
    public func reset() { edit { $0.reset() } }
    public func toggleLearning() { edit { $0.isLearning ? $0.cancelLearning() : $0.beginLearning() } }

    /// A MIDI message, as if it came through the environment. The environment's `midi` is
    /// already wired to this.
    @discardableResult
    public func receive(_ message: MIDIMessage) -> LiveMIDIReception {
        if !midiLearning {
            guard !midiAutomated, midiAddresses.contains(where: { $0.value(in: message) != nil }) else { return .ignored }
        }
        var next = state
        let reception = next.receive(message)
        if reception != .ignored { state = next }
        return reception
    }

    // MARK: Wiring

    private func refreshMIDIFilter() {
        midiLearning = state.isLearning
        midiAutomated = state.isAutomated
        midiAddresses = state.midiAddresses
        paceID = state.paceReference
        pulseWidthID = state.pulseWidthReference
        // A remembered lookup is dropped when its reference changes, so a step need not compare ids.
        if paceTarget?.id != paceID { paceTarget = nil }
        if pulseWidthTarget?.id != pulseWidthID { pulseWidthTarget = nil }
    }

    private func stateDidChange() {
        refreshMIDIFilter()
        if state.value != valueSubject.value { valueSubject.send(state.value) }
        reconcile()
    }

    /// Brings the subscriptions in line with what the state needs now.
    private func reconcile() {
        guard let environment else {
            clockToken = nil; sourceToken = nil; dropMIDI(); subscribedSource = nil
            return
        }
        reconcileMIDI(environment)
        if state.needsClock {
            if clockToken == nil {
                clockToken = environment.clock.sink { [unowned(unsafe) self] tick in self.advance(by: tick) }
            }
        } else {
            clockToken = nil
        }

        let wanted = state.isAutomated ? state.source?.descriptor : nil
        if wanted != subscribedSource {
            sourceToken = nil; latestSourceValue = nil; subscribedSource = wanted
            if let wanted {
                sourceToken = environment.publisher(for: wanted)?.sink { [unowned(unsafe) self] value in
                    self.latestSourceValue = value
                }
            }
        }
    }

    /// Listens to the messages that matter: each followed address through the host's route, and
    /// the whole stream only while learning or when the host has no routes. Automation ignores
    /// MIDI, so while it runs nothing is followed.
    private func reconcileMIDI(_ environment: any LiveParameterEnvironment) {
        let wanted = state.isAutomated ? [] : state.midiAddresses
        if wanted != routedAddresses {
            addressTokens = []
            routedAddresses = wanted
            needsAllMIDI = false
            for address in wanted {
                if let route = environment.midi(for: address) {
                    // While learning, the whole-stream subscription is the one that listens.
                    addressTokens.append(route.sink { [unowned(unsafe) self] message in
                        if !self.midiLearning { self.receive(message) }
                    })
                } else {
                    needsAllMIDI = true
                }
            }
        }
        if state.isLearning || needsAllMIDI {
            if allMIDIToken == nil {
                allMIDIToken = environment.midi.sink { [unowned(unsafe) self] message in self.receive(message) }
            }
        } else {
            allMIDIToken = nil
        }
    }

    private func dropMIDI() {
        allMIDIToken = nil; addressTokens = []; routedAddresses = nil; needsAllMIDI = false
    }

    private func advance(by clockTick: LiveClockTick) {
        let pace = paceID.flatMap { referencedValue($0, cache: &paceTarget) } ?? 1
        let width = pulseWidthID.flatMap { referencedValue($0, cache: &pulseWidthTarget) }
        ticking = true
        state.tick(LiveTick(deltaTime: clockTick.deltaTime, bpm: clockTick.bpm, pace: pace,
                            pulseWidth: width, sourceValue: latestSourceValue))
        ticking = false
        if state.value != valueSubject.value { valueSubject.send(state.value) }
        if !state.needsClock { clockToken = nil }
    }

    /// The value of the parameter a reference names. The lookup is remembered, so a step does not
    /// search the host again; a parameter that is not there yet is looked for on the next step.
    private func referencedValue(_ id: LiveObjectID, cache: inout WeakReference?) -> Double? {
        if let parameter = cache?.parameter { return parameter.value }
        guard let parameter = environment?.parameter(withID: id) else { cache = nil; return nil }
        cache = WeakReference(parameter: parameter, id: id)
        return parameter.value
    }
}
