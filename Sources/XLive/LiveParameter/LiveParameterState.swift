import Foundation

/// The state of a parameter and every change it can undergo, with no clock, no subscriptions
/// and no globals. It is a plain value: you can copy it, save it, and test it by calling its
/// methods. `LiveParameter` is the object that owns one and feeds it from a clock, sources and
/// MIDI by subscribing; nothing else needs to call `tick(_:)`.
///
/// A parameter is a bounded value that can be set by hand, driven by an automation source (its
/// own LFO, audio, motion or a gamepad), or followed from MIDI. Hand and MIDI set it at once;
/// while automation is on, each `tick` writes it again and MIDI is ignored. `reset()` turns
/// automation off and glides the value back to `defaultValue`.
public struct LiveParameterState: Sendable, Codable, Identifiable {
    public let id: LiveObjectID
    public var label: String
    public private(set) var mapping: LiveValueMapping
    public private(set) var defaultValue: Double
    /// Any write releases the MIDI control that held the value; `receive` engages it again after
    /// its own write.
    public private(set) var value: Double { didSet { takeover.release() } }

    // Automation
    public private(set) var source: LiveAutomationSource?
    public private(set) var automationIsOn: Bool
    /// Flips the automated signal (not the hand or MIDI value).
    public private(set) var inverse: Bool
    /// 0...1. 0.5 leaves an automated signal as it is. For MIDI it is the response curve.
    public private(set) var amount: Double
    public private(set) var lfo: LiveLFO
    public private(set) var wave: LiveWave
    public private(set) var audioEnvelope: LiveEnvelope
    /// Parameters the host resolves into `LiveTick.pace` and `LiveTick.pulseWidth`.
    public private(set) var paceReference: LiveObjectID?
    public private(set) var pulseWidthReference: LiveObjectID?

    // MIDI
    public private(set) var midiAddresses: [LiveMIDIAddress]
    public private(set) var isLearning = false
    /// Which control holds the value and where it last was. Runtime only: not saved.
    public private(set) var takeover = LiveTakeover()

    // Runtime only: not saved.
    private var phase = LivePhase()
    private var smoother: LiveEnvelope
    private var resetGlide: Glide?

    private struct Glide: Sendable {
        let start: Double
        var elapsed = 0.0
        static let duration = 0.3
    }

    private static let unitLFO = try! LiveLFO(period: .beats(1))
    private static let defaultMapping = try! LiveValueMapping()
    private static let defaultWave = LiveWave()
    private static let defaultAudioEnvelope = LiveEnvelope(perFrameRise: 0.3, fall: 0.1)
    private static func makeSmoother(_ value: Double) -> LiveEnvelope {
        LiveEnvelope(perFrameRise: 0.2, fall: 0.2, initial: value)
    }

    public init(id: LiveObjectID = LiveObjectID(rawValue: UUID().uuidString), label: String = "",
                value: Double, mapping: LiveValueMapping? = nil) throws {
        let mapping = try mapping ?? LiveValueMapping()
        guard let constrained = mapping.constrained(value) else { throw LiveParameterError.invalidValue }
        self.id = id; self.label = label; self.mapping = mapping
        self.defaultValue = constrained; self.value = constrained
        source = nil; automationIsOn = false; inverse = false; amount = 0.5
        lfo = Self.unitLFO; wave = Self.defaultWave; audioEnvelope = Self.defaultAudioEnvelope
        midiAddresses = []
        smoother = Self.makeSmoother(constrained)
    }

    // MARK: What a slider shows

    public var isAutomated: Bool { source != nil && automationIsOn }
    /// Whether the clock has anything to do: automation is running, a reset is gliding, or the
    /// smoothed value has not yet caught up. When false, the owner can stop listening to it.
    public var needsClock: Bool { isAutomated || resetGlide != nil || smoother.value != value }
    public var normalizedValue: Double { mapping.normalized(value) }
    public var smoothedValue: Double { smoother.value }
    public var valueText: String { LiveValueFormat.text(value) }
    public var midiState: LiveMIDIState {
        if isLearning { return .learning }
        return midiAddresses.isEmpty ? .none : .assigned
    }

    // MARK: Hand

    /// Sets the value now, snapped to the step and clamped. Non-finite input is ignored.
    /// While automation is on the next `tick` writes over it.
    public mutating func setManualValue(_ newValue: Double) {
        guard let constrained = mapping.constrained(newValue) else { return }
        value = constrained; resetGlide = nil
    }

    public mutating func setNormalizedManualValue(_ normalized: Double) {
        guard let constrained = mapping.value(forNormal: normalized) else { return }
        value = constrained; resetGlide = nil
    }

    /// Changes the range, limit and step; the value and the default are held inside the new bounds.
    public mutating func setMapping(_ newMapping: LiveValueMapping) {
        mapping = newMapping
        value = newMapping.constrained(value) ?? newMapping.reachable.lowerBound
        defaultValue = newMapping.constrained(defaultValue) ?? newMapping.reachable.lowerBound
    }

    public mutating func setDefaultValue(_ newValue: Double) {
        if let constrained = mapping.constrained(newValue) { defaultValue = constrained }
    }

    /// Turns automation off and glides the value to `defaultValue` over 0.3 seconds.
    public mutating func reset() {
        automationIsOn = false
        resetGlide = value == defaultValue ? nil : Glide(start: value)
    }

    // MARK: Automation settings

    public mutating func setSource(_ newSource: LiveAutomationSource?) {
        guard newSource != source else { return }
        source = newSource; resetGlide = nil
    }

    public mutating func setAutomation(on: Bool) {
        guard on != automationIsOn else { return }
        automationIsOn = on; resetGlide = nil
    }

    public mutating func toggleAutomation() { setAutomation(on: !automationIsOn) }
    public mutating func setInverse(_ newValue: Bool) { inverse = newValue }
    public mutating func setAmount(_ newValue: Double) { if newValue.isFinite { amount = min(1, max(0, newValue)) } }
    public mutating func setLFO(_ newValue: LiveLFO) { lfo = newValue }
    public mutating func setWave(_ newValue: LiveWave) { wave = newValue }
    public mutating func setAudioEnvelope(attack: Double, release: Double) {
        audioEnvelope = LiveEnvelope(attack: attack, release: release, initial: audioEnvelope.value)
    }
    public mutating func setPaceReference(_ reference: LiveObjectID?) { paceReference = reference }
    public mutating func setPulseWidthReference(_ reference: LiveObjectID?) { pulseWidthReference = reference }

    // MARK: MIDI

    public mutating func beginLearning() { isLearning = true }
    public mutating func cancelLearning() { isLearning = false }

    public mutating func assign(_ address: LiveMIDIAddress) {
        if !midiAddresses.contains(address) { midiAddresses.append(address) }
    }
    public mutating func unassign(_ address: LiveMIDIAddress) { midiAddresses.removeAll { $0 == address } }
    public mutating func clearMIDI() { midiAddresses.removeAll(); isLearning = false }

    /// While learning, the first learnable message adds its control and ends learning without
    /// moving the value. Otherwise a message for an assigned control sets the value through the
    /// response curve of `amount`, unless automation is on, which ignores MIDI.
    ///
    /// With `.pickup` a controller that does not hold the value is `.waiting`: it sets nothing
    /// until it reaches the value (see `LiveTakeover`). Notes always set the value at once.
    @discardableResult
    public mutating func receive(_ message: MIDIMessage, takeover mode: LiveTakeoverMode = .pickup) -> LiveMIDIReception {
        if isLearning {
            guard let learned = LiveMIDIAddress(learning: message) else { return .ignored }
            assign(learned); isLearning = false
            return .learned(learned)
        }
        guard !isAutomated else { return .ignored }
        for address in midiAddresses {
            guard let raw = address.value(in: message) else { continue }
            let position = LiveAmount.response(Double(raw) / 127, curve: amount)
            guard let constrained = mapping.value(forNormal: position) else { return .ignored }
            let reached = takeover.accepts(position, from: address, current: mapping.normalized(value), tolerance: takeoverTolerance)
            guard reached || mode == .jump || address.kind == .note else { return .waiting }
            value = constrained; resetGlide = nil
            takeover.engage(address)
            return .applied(constrained)
        }
        return .ignored
    }

    /// How close a control must be to count as on the value: a step of the control, or half a
    /// step of the value when it is quantised more coarsely than that.
    private var takeoverTolerance: Double {
        guard let step = mapping.step else { return LiveTakeover.tolerance }
        return max(LiveTakeover.tolerance, step / 2 / (mapping.range.upperBound - mapping.range.lowerBound))
    }

    // MARK: Clock

    /// Whether `receive` would do anything with this message. Answers without changing the
    /// state, so a host with many parameters can skip the ones a message does not concern.
    func reacts(to message: MIDIMessage) -> Bool {
        if isLearning { return LiveMIDIAddress(learning: message) != nil }
        guard !isAutomated else { return false }
        return midiAddresses.contains { $0.value(in: message) != nil }
    }

    /// Advances the parameter by one clock step. A negative or non-finite step does nothing.
    public mutating func tick(_ tick: LiveTick) {
        guard tick.deltaTime.isFinite, tick.deltaTime >= 0 else { return }
        if var glide = resetGlide {
            glide.elapsed += tick.deltaTime
            let progress = min(1, glide.elapsed / Glide.duration)
            let eased = progress * progress * (3 - 2 * progress)
            value = mapping.constrained(glide.start + (defaultValue - glide.start) * eased) ?? defaultValue
            resetGlide = progress >= 1 ? nil : glide
        } else if isAutomated, let source, let normal = sample(source, tick) {
            let scaled = LiveAmount.scale(normal, around: source.amountCenter, amount: amount)
            if let next = mapping.value(forNormal: inverse ? 1 - scaled : scaled) { value = next }
        }
        smoother.process(value, deltaTime: tick.deltaTime)
        if abs(smoother.value - value) <= 0.001 { smoother.reset(to: value) }   // settled
    }

    /// The source's position this step, 0...1, or nil when there is nothing to follow.
    private mutating func sample(_ source: LiveAutomationSource, _ tick: LiveTick) -> Double? {
        switch source {
        case .lfo:
            phase.advance(seconds: tick.deltaTime, period: lfo.period, bpm: tick.bpm, pace: tick.pace)
            var shaped = wave
            if let width = tick.pulseWidth { shaped.setPulseWidth(width) }
            return shaped.sample(cycles: phase.cycles + lfo.phase)
        case .audio:
            guard let level = tick.sourceValue, level.isFinite else { return nil }
            return audioEnvelope.process(min(1, max(0, level)), deltaTime: tick.deltaTime)
        case .motion, .gamepad:
            guard let level = tick.sourceValue, level.isFinite else { return nil }
            return min(1, max(0, level))
        }
    }

    // MARK: Codable
    //
    // Written flat and sparse. A parameter is saved by the hundred, and every nested container
    // costs the encoder and decoder about as much as a whole simple parameter: so the range,
    // LFO, wave, source and MIDI addresses are plain keys or one short value, and anything equal
    // to a new parameter's setting is left out. Reading accepts the earlier nested form too.

    private enum CodingKeys: String, CodingKey {
        case id, label, value, defaultValue, source, automationIsOn, inverse, amount
        case audioEnvelope, paceReference, pulseWidthReference, midiAddresses
        case min, max, limitMin, limitMax, step
        case lfoBeats, lfoSeconds, lfoPhase
        case waveShape, pulseWidth, seed
        case mapping, lfo, wave   // the earlier nested form, read only
    }

    /// Restores through the validating initializers. Learning, the LFO position, the smoothing
    /// and a reset in progress are not saved.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let f = Fields(c: c, present: c.allKeys)
        try self.init(id: c.decode(LiveObjectID.self, forKey: .id),
                      label: f.get(String.self, .label) ?? "",
                      value: c.decode(Double.self, forKey: .value), mapping: Self.decodeMapping(f))
        setDefaultValue(try f.get(Double.self, .defaultValue) ?? value)
        source = try Self.decodeSource(f)
        automationIsOn = try f.get(Bool.self, .automationIsOn) ?? false
        inverse = try f.get(Bool.self, .inverse) ?? false
        if let decoded = try f.get(Double.self, .amount) {
            guard decoded.isFinite else { throw LiveParameterError.invalidValue }
            amount = min(1, max(0, decoded))
        }
        lfo = try Self.decodeLFO(f)
        wave = try Self.decodeWave(f)
        if let envelope = try f.get(LiveEnvelope.self, .audioEnvelope) {
            audioEnvelope = LiveEnvelope(attack: envelope.attack, release: envelope.release)
        }
        paceReference = try f.get(LiveObjectID.self, .paceReference)
        pulseWidthReference = try f.get(LiveObjectID.self, .pulseWidthReference)
        for address in try f.get([PackedAddress].self, .midiAddresses) ?? [] { assign(try address.address()) }
    }

    /// Writes only what differs from a new parameter. `init(from:)` fills in the rest, and also
    /// reads files that spell everything out.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if !label.isEmpty { try c.encode(label, forKey: .label) }
        try c.encode(value, forKey: .value)
        if defaultValue != value { try c.encode(defaultValue, forKey: .defaultValue) }
        if mapping != Self.defaultMapping {
            if mapping.range.lowerBound != 0 { try c.encode(mapping.range.lowerBound, forKey: .min) }
            if mapping.range.upperBound != 1 { try c.encode(mapping.range.upperBound, forKey: .max) }
            if let limit = mapping.limit {
                try c.encode(limit.lowerBound, forKey: .limitMin); try c.encode(limit.upperBound, forKey: .limitMax)
            }
            try c.encodeIfPresent(mapping.step, forKey: .step)
        }
        if let source { try c.encode(Self.text(of: source), forKey: .source) }
        if automationIsOn { try c.encode(true, forKey: .automationIsOn) }
        if inverse { try c.encode(true, forKey: .inverse) }
        if amount != 0.5 { try c.encode(amount, forKey: .amount) }
        if lfo != Self.unitLFO {
            switch lfo.period {
            case .beats(let length): try c.encode(length, forKey: .lfoBeats)
            case .seconds(let length): try c.encode(length, forKey: .lfoSeconds)
            }
            if lfo.phase != 0 { try c.encode(lfo.phase, forKey: .lfoPhase) }
        }
        if wave != Self.defaultWave {
            if wave.shape != Self.defaultWave.shape { try c.encode(wave.shape, forKey: .waveShape) }
            if wave.pulseWidth != Self.defaultWave.pulseWidth { try c.encode(wave.pulseWidth, forKey: .pulseWidth) }
            if wave.seed != 0 { try c.encode(wave.seed, forKey: .seed) }
        }
        if audioEnvelope.attack != Self.defaultAudioEnvelope.attack || audioEnvelope.release != Self.defaultAudioEnvelope.release {
            try c.encode(audioEnvelope, forKey: .audioEnvelope)
        }
        try c.encodeIfPresent(paceReference, forKey: .paceReference)
        try c.encodeIfPresent(pulseWidthReference, forKey: .pulseWidthReference)
        if !midiAddresses.isEmpty { try c.encode(midiAddresses.map(PackedAddress.init), forKey: .midiAddresses) }
    }

    /// The keys a saved parameter actually has, read once: asking a keyed container for a key it
    /// lacks costs a lookup each, and most keys are absent from a sparse file.
    private struct Fields {
        let c: KeyedDecodingContainer<CodingKeys>
        let present: [CodingKeys]
        func has(_ key: CodingKeys) -> Bool { present.contains(key) }
        func get<T: Decodable>(_ type: T.Type, _ key: CodingKeys) throws -> T? {
            has(key) ? try c.decodeIfPresent(type, forKey: key) : nil
        }
    }

    private static func corrupted(_ key: CodingKeys, _ c: KeyedDecodingContainer<CodingKeys>, _ why: String) -> DecodingError {
        .dataCorruptedError(forKey: key, in: c, debugDescription: why)
    }

    private static func decodeMapping(_ f: Fields) throws -> LiveValueMapping? {
        if let legacy = try f.get(LiveValueMapping.self, .mapping) { return legacy }
        let lower = try f.get(Double.self, .min), upper = try f.get(Double.self, .max)
        let limitLower = try f.get(Double.self, .limitMin), limitUpper = try f.get(Double.self, .limitMax)
        let step = try f.get(Double.self, .step)
        if lower == nil, upper == nil, limitLower == nil, limitUpper == nil, step == nil { return nil }
        // A range literal traps when its bounds are out of order, so check before building one.
        let low = lower ?? 0, high = upper ?? 1
        guard low <= high else { throw corrupted(.min, f.c, "The range is out of order") }
        var limit: ClosedRange<Double>?
        if limitLower != nil || limitUpper != nil {
            guard let limitLower, let limitUpper, limitLower <= limitUpper else { throw corrupted(.limitMin, f.c, "The limit is incomplete or out of order") }
            limit = limitLower...limitUpper
        }
        return try LiveValueMapping(range: low...high, limit: limit, step: step)
    }

    private static func decodeLFO(_ f: Fields) throws -> LiveLFO {
        if let legacy = try f.get(LiveLFO.self, .lfo) { return legacy }
        let beats = try f.get(Double.self, .lfoBeats), seconds = try f.get(Double.self, .lfoSeconds)
        let phase = try f.get(Double.self, .lfoPhase)
        if beats == nil, seconds == nil, phase == nil { return unitLFO }
        if beats != nil, seconds != nil { throw corrupted(.lfoBeats, f.c, "An LFO period is in beats or in seconds, not both") }
        let period: LiveLFO.Period = seconds.map { .seconds($0) } ?? .beats(beats ?? 1)
        return try LiveLFO(period: period, phase: phase ?? 0)
    }

    private static func decodeWave(_ f: Fields) throws -> LiveWave {
        if let legacy = try f.get(LiveWave.self, .wave) { return legacy }
        let shape = try f.get(LiveWaveShape.self, .waveShape)
        let width = try f.get(Double.self, .pulseWidth), seed = try f.get(UInt64.self, .seed)
        if shape == nil, width == nil, seed == nil { return defaultWave }
        return LiveWave(shape: shape ?? defaultWave.shape, pulseWidth: width ?? defaultWave.pulseWidth, seed: seed ?? 0)
    }

    /// "lfo", "audio:low", "motion:roll", "gamepad:<id>". The earlier form was a nested object.
    private static func text(of source: LiveAutomationSource) -> String {
        switch source {
        case .lfo: return "lfo"
        case .audio(let band): return "audio:" + band.rawValue
        case .motion(let axis): return "motion:" + axis.rawValue
        case .gamepad(let id): return "gamepad:" + id
        }
    }

    private static func decodeSource(_ f: Fields) throws -> LiveAutomationSource? {
        guard f.has(.source) else { return nil }
        guard let text = try? f.c.decode(String.self, forKey: .source) else {
            return try f.c.decode(LiveAutomationSource.self, forKey: .source)
        }
        if text == "lfo" { return .lfo }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let name = String(parts[1])
            switch parts[0] {
            case "audio": if let band = LiveAudioBand(rawValue: name) { return .audio(band) }
            case "motion": if let axis = LiveMotionAxis(rawValue: name) { return .motion(axis) }
            case "gamepad": return .gamepad(id: name)
            default: break
            }
        }
        throw corrupted(.source, f.c, "Unknown automation source \"\(text)\"")
    }

    /// An address as one integer: kind in bit 11, channel in bits 7...10, number in bits 0...6.
    /// The earlier form was an object with those three fields, which is still read.
    private struct PackedAddress: Codable {
        let kind: LiveMIDIAddress.Kind, channel: UInt8, number: UInt8

        init(kind: LiveMIDIAddress.Kind, channel: UInt8, number: UInt8) { self.kind = kind; self.channel = channel; self.number = number }
        init(_ address: LiveMIDIAddress) { self.init(kind: address.kind, channel: address.channel, number: address.number) }

        func address() throws -> LiveMIDIAddress { try LiveMIDIAddress(kind: kind, channel: channel, number: number) }

        init(from decoder: any Decoder) throws {
            if let packed = try? decoder.singleValueContainer().decode(Int.self) {
                guard (0..<4096).contains(packed) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "MIDI address out of range"))
                }
                self.init(kind: packed & 0x800 == 0 ? .control : .note,
                          channel: UInt8((packed >> 7) & 0xF), number: UInt8(packed & 0x7F))
            } else {
                self.init(try LiveMIDIAddress(from: decoder))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode((kind == .note ? 0x800 : 0) | Int(channel) << 7 | Int(number))
        }
    }

}
