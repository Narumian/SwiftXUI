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
