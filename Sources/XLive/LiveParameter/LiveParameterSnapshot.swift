import Foundation

/// The persistent settings of a parameter, without its runtime identity, MIDI learn state,
/// automation phase, smoothing, or reset glide. A Cue can store this by parameter key and use it
/// to restore the control into a newly created node.
public struct LiveParameterSnapshot: Codable, Hashable, Sendable {
    public let label: String
    public let value: Double
    public let defaultValue: Double
    public let mapping: LiveValueMapping
    public let source: LiveAutomationSource?
    public let automationIsOn: Bool
    public let inverse: Bool
    public let amount: Double
    public let lfo: LiveLFO
    public let wave: LiveWave
    public let audioAttack: Double
    public let audioRelease: Double
    public let paceReference: LiveObjectID?
    public let pulseWidthReference: LiveObjectID?
    public let midiAddresses: [LiveMIDIAddress]

    public init(_ state: LiveParameterState) {
        label = state.label
        value = state.value
        defaultValue = state.defaultValue
        mapping = state.mapping
        source = state.source
        automationIsOn = state.automationIsOn
        inverse = state.inverse
        amount = state.amount
        lfo = state.lfo
        wave = state.wave
        audioAttack = state.audioEnvelope.attack
        audioRelease = state.audioEnvelope.release
        paceReference = state.paceReference
        pulseWidthReference = state.pulseWidthReference
        midiAddresses = state.midiAddresses
    }
}

public extension LiveParameterSnapshot {
    /// Whether two snapshots set a parameter up the same way. The value is left out: an automated
    /// parameter's value changes every frame, and a settings change is not a value change.
    func hasSameSettings(as other: LiveParameterSnapshot) -> Bool {
        label == other.label && defaultValue == other.defaultValue && mapping == other.mapping
            && source == other.source && automationIsOn == other.automationIsOn && inverse == other.inverse
            && amount == other.amount && lfo == other.lfo && wave == other.wave
            && audioAttack == other.audioAttack && audioRelease == other.audioRelease
            && paceReference == other.paceReference && pulseWidthReference == other.pulseWidthReference
            && midiAddresses == other.midiAddresses
    }
}

public extension LiveParameterState {
    /// Sets the parameter up as `settings` says, apart from its value, which stays where it is (held inside the
    /// restored range). Anything that is already the same is left alone, so a running LFO keeps its phase and an
    /// envelope its level.
    mutating func apply(settings: LiveParameterSnapshot) {
        if label != settings.label { label = settings.label }
        if mapping != settings.mapping { setMapping(settings.mapping) }
        if defaultValue != settings.defaultValue { setDefaultValue(settings.defaultValue) }
        setSource(settings.source)
        setAutomation(on: settings.automationIsOn)
        if inverse != settings.inverse { setInverse(settings.inverse) }
        if amount != settings.amount { setAmount(settings.amount) }
        if lfo != settings.lfo { setLFO(settings.lfo) }
        if wave != settings.wave { setWave(settings.wave) }
        if audioEnvelope.attack != settings.audioAttack || audioEnvelope.release != settings.audioRelease {
            setAudioEnvelope(attack: settings.audioAttack, release: settings.audioRelease)
        }
        if paceReference != settings.paceReference { setPaceReference(settings.paceReference) }
        if pulseWidthReference != settings.pulseWidthReference { setPulseWidthReference(settings.pulseWidthReference) }
        if midiAddresses != settings.midiAddresses {
            clearMIDI()
            for address in settings.midiAddresses { assign(address) }
        }
    }
}

public extension LiveParameter {
    func apply(settings: LiveParameterSnapshot) { edit { $0.apply(settings: settings) } }
}
