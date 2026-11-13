import XCTest
import XLive

final class LiveParameterStateTests: XCTestCase {
    private func make(range: ClosedRange<Double> = 0...10, value: Double = 0, step: Double? = nil,
                      limit: ClosedRange<Double>? = nil) throws -> LiveParameterState {
        try LiveParameterState(label: "p", value: value, mapping: LiveValueMapping(range: range, limit: limit, step: step))
    }

    private func cc(_ number: UInt8, _ value: UInt8, channel: UInt8 = 0) -> MIDIMessage {
        .controlChange(channel: channel, controller: number, value: value)
    }

    // MARK: LFO

    func testLFOFollowsItsWaveOnlyWhileAutomationIsOn() throws {
        var p = try make()
        p.setSource(.lfo)
        p.setLFO(try LiveLFO(period: .seconds(4)))
        p.tick(LiveTick(deltaTime: 1))
        XCTAssertEqual(p.value, 0, "a source alone does not run")
        p.setAutomation(on: true)
        XCTAssertTrue(p.isAutomated)
        p.tick(LiveTick(deltaTime: 0))
        XCTAssertEqual(p.value, 5, accuracy: 1e-9, "sine starts at the midpoint")
        p.tick(LiveTick(deltaTime: 1))
        XCTAssertEqual(p.value, 10, accuracy: 1e-9, "a quarter cycle later it is at the top")
        p.tick(LiveTick(deltaTime: 2))
        XCTAssertEqual(p.value, 0, accuracy: 1e-9)
        p.setAutomation(on: false)
        p.tick(LiveTick(deltaTime: 1))
        XCTAssertEqual(p.value, 0, "off holds")
    }

    func testBeatLengthLFOFollowsTempoAndPace() throws {
        var p = try make()
        p.setSource(.lfo); p.setAutomation(on: true)
        p.setLFO(try LiveLFO(period: .beats(4)))
        p.setWave(LiveWave(shape: .saw))
        p.tick(LiveTick(deltaTime: 1, bpm: 120))      // 2 of 4 beats
        XCTAssertEqual(p.value, 5, accuracy: 1e-9)
        p.tick(LiveTick(deltaTime: 1, bpm: nil))       // no tempo: the phase holds
        XCTAssertEqual(p.value, 5, accuracy: 1e-9)
        p.tick(LiveTick(deltaTime: 0.5, bpm: 120, pace: 2))  // 2 more beats: a whole cycle, back to the start
        XCTAssertEqual(p.value, 0, accuracy: 1e-9)
        p.tick(LiveTick(deltaTime: 0.25, bpm: 120, pace: 1))  // half a beat of four
        XCTAssertEqual(p.value, 1.25, accuracy: 1e-9)
    }

    func testNoiseLFODoesNotJumpAtCycleBoundary() throws {
        var p = try make(range: -360...360)
        p.setSource(.lfo); p.setAutomation(on: true)
        p.setLFO(try LiveLFO(period: .seconds(1)))
        p.setWave(LiveWave(shape: .noise, seed: 5))
        p.tick(LiveTick(deltaTime: 0.999_999))
        let before = p.value
        p.tick(LiveTick(deltaTime: 0.000_002))
        XCTAssertEqual(p.value, before, accuracy: 1e-5)
    }

    func testPulseWidthComesFromTheTick() throws {
        var p = try make()
        p.setSource(.lfo); p.setAutomation(on: true)
        p.setLFO(try LiveLFO(period: .seconds(1)))
        p.setWave(LiveWave(shape: .pwm, pulseWidth: 0.1))
        p.setPaceReference(LiveObjectID(rawValue: "pace")); p.setPulseWidthReference(LiveObjectID(rawValue: "pw"))
        p.tick(LiveTick(deltaTime: 0.3, pulseWidth: 0.5))
        XCTAssertEqual(p.value, 10, "0.3 is inside a 0.5 pulse")
        p.tick(LiveTick(deltaTime: 0, pulseWidth: 0.2))
        XCTAssertEqual(p.value, 0, "and outside a 0.2 pulse")
        XCTAssertEqual(p.wave.pulseWidth, 0.1, "the stored width is not rewritten")
    }

    // MARK: Amount and inverse

    func testAmountScalesAroundTheSourceCenterAndInverseFlips() throws {
        var p = try make(range: 0...1)
        p.setSource(.motion(.roll)); p.setAutomation(on: true)
        p.tick(LiveTick(deltaTime: 0.01, sourceValue: 1))
        XCTAssertEqual(p.value, 1, accuracy: 1e-12, "amount 0.5 leaves it as is")
        p.setAmount(0.25)
        p.tick(LiveTick(deltaTime: 0.01, sourceValue: 1))
        XCTAssertEqual(p.value, 0.75, accuracy: 1e-12, "gain 0.5 around 0.5")
        p.setAmount(0)
        p.tick(LiveTick(deltaTime: 0.01, sourceValue: 1))
        XCTAssertEqual(p.value, 0.5, accuracy: 1e-12, "gain 0 collapses to the center")
        p.setAmount(0.5); p.setInverse(true)
        p.tick(LiveTick(deltaTime: 0.01, sourceValue: 0.8))
        XCTAssertEqual(p.value, 0.2, accuracy: 1e-12)
        p.setAmount(1); p.setInverse(false)
        p.tick(LiveTick(deltaTime: 0.01, sourceValue: 0.6))
        XCTAssertEqual(p.value, 1, accuracy: 1e-12, "gain 100 overshoots and the range clamps")
        p.setAmount(.nan)
        XCTAssertEqual(p.amount, 1)
    }

    func testAudioRestsAtZeroAndFollowsWithAnEnvelope() throws {
        var p = try make(range: 0...1)
        p.setSource(.audio(.low)); p.setAutomation(on: true)
        p.setAudioEnvelope(attack: 0.1, release: 1)
        p.tick(LiveTick(deltaTime: 0.1, sourceValue: 1))
        XCTAssertEqual(p.value, 1 - exp(-1), accuracy: 1e-9)
        let peak = p.value
        p.tick(LiveTick(deltaTime: 1, sourceValue: 0))
        XCTAssertEqual(p.value, peak * exp(-1), accuracy: 1e-9)
        let held = p.value
        p.tick(LiveTick(deltaTime: 1, sourceValue: nil))
        XCTAssertEqual(p.value, held, "no signal holds")
        p.setAmount(0.25)   // gain 0.5 around 0 for audio
        p.tick(LiveTick(deltaTime: 100, sourceValue: 1))
        XCTAssertEqual(p.value, 0.5, accuracy: 1e-6)
    }

    func testMotionAndGamepadReadTheSuppliedValue() throws {
        for source in [LiveAutomationSource.motion(.pitch), .gamepad(id: "pad")] {
            var p = try make()
            p.setSource(source); p.setAutomation(on: true)
            p.tick(LiveTick(deltaTime: 0.01, sourceValue: 0.3))
            XCTAssertEqual(p.value, 3, accuracy: 1e-9)
            p.tick(LiveTick(deltaTime: 0.01, sourceValue: 7))
            XCTAssertEqual(p.value, 10, "clamped to 0...1 first")
            p.tick(LiveTick(deltaTime: 0.01, sourceValue: .nan))
            XCTAssertEqual(p.value, 10)
        }
        XCTAssertNil(LiveAutomationSource.lfo.descriptor)
        XCTAssertEqual(LiveAutomationSource.audio(.mid).descriptor, .audio(.mid))
        XCTAssertEqual(LiveAutomationSource.audio(.mid).amountCenter, 0)
        XCTAssertEqual(LiveAutomationSource.gamepad(id: "x").amountCenter, 0.5)
    }

    // MARK: Hand, reset, mapping

    func testHandSetsAtOnceAndAutomationWritesOverIt() throws {
        var p = try make(step: 2)
        p.setManualValue(5.1)
        XCTAssertEqual(p.value, 6)
        p.setManualValue(.nan); p.setNormalizedManualValue(.infinity)
        XCTAssertEqual(p.value, 6)
        p.setNormalizedManualValue(2)
        XCTAssertEqual(p.value, 10)
        p.setSource(.gamepad(id: "g")); p.setAutomation(on: true)
        p.setManualValue(0)
        p.tick(LiveTick(deltaTime: 0.01, sourceValue: 1))
        XCTAssertEqual(p.value, 10)
    }

    func testResetGlidesToTheDefaultAndStopsAutomation() throws {
        var p = try make(value: 2)
        p.setSource(.gamepad(id: "g")); p.setAutomation(on: true)
        p.setManualValue(10)
        p.reset()
        XCTAssertFalse(p.automationIsOn)
        p.tick(LiveTick(deltaTime: 0.15, sourceValue: 1))
        XCTAssertEqual(p.value, 6, accuracy: 1e-9, "halfway through smoothstep is halfway")
        p.tick(LiveTick(deltaTime: 0.15))
        XCTAssertEqual(p.value, 2, accuracy: 1e-9)
        p.tick(LiveTick(deltaTime: 1))
        XCTAssertEqual(p.value, 2)
        p.setManualValue(9); p.reset(); p.setManualValue(4)
        p.tick(LiveTick(deltaTime: 1))
        XCTAssertEqual(p.value, 4, "a hand move cancels the glide")
    }

    func testChangingTheMappingHoldsTheValueInsideIt() throws {
        var p = try make(range: 0...10, value: 8)
        p.setDefaultValue(9)
        p.setMapping(try LiveValueMapping(range: 0...5, step: 1))
        XCTAssertEqual(p.value, 5); XCTAssertEqual(p.defaultValue, 5)
        XCTAssertEqual(p.normalizedValue, 1)
        XCTAssertThrowsError(try make(value: .nan))
    }

    func testSmoothedValueFollowsInTime() throws {
        var p = try make(range: 0...1)
        p.setManualValue(1)
        p.tick(LiveTick(deltaTime: 1.0 / 60))
        XCTAssertEqual(p.smoothedValue, 0.2, accuracy: 1e-9, "20% of the gap per 60 Hz frame, as before")
        for _ in 0..<600 { p.tick(LiveTick(deltaTime: 1.0 / 60)) }
        XCTAssertEqual(p.smoothedValue, 1, accuracy: 1e-6)
        var skipped = p
        skipped.tick(LiveTick(deltaTime: -1)); skipped.tick(LiveTick(deltaTime: .nan))
        XCTAssertEqual(skipped.smoothedValue, p.smoothedValue)
    }

    // MARK: MIDI

    func testLearnAssignAndFollowMIDI() throws {
        var p = try make()
        XCTAssertEqual(p.midiState, .none)
        p.beginLearning()
        XCTAssertEqual(p.midiState, .learning)
        XCTAssertEqual(p.receive(.noteOff(channel: 0, note: 1, velocity: 0), takeover: .jump), .ignored)
        let learned = try LiveMIDIAddress(kind: .control, channel: 1, number: 7)
        XCTAssertEqual(p.receive(cc(7, 127, channel: 1), takeover: .jump), .learned(learned))
        XCTAssertEqual(p.midiState, .assigned)
        XCTAssertEqual(p.value, 0, "the learning message does not move the value")
        XCTAssertEqual(p.receive(cc(7, 127, channel: 1), takeover: .jump), .applied(10))
        XCTAssertEqual(p.receive(cc(7, 127, channel: 2), takeover: .jump), .ignored)
        p.assign(try LiveMIDIAddress(kind: .note, channel: 9, number: 36))
        p.assign(learned)
        XCTAssertEqual(p.midiAddresses.count, 2, "no duplicates")
        XCTAssertEqual(p.receive(.noteOn(channel: 9, note: 36, velocity: 0), takeover: .jump), .applied(0))
        p.unassign(learned)
        XCTAssertEqual(p.receive(cc(7, 127, channel: 1), takeover: .jump), .ignored)
        p.clearMIDI()
        XCTAssertEqual(p.midiState, .none)
    }

    func testMIDIIsIgnoredWhileAutomatedAndUsesTheAmountAsACurve() throws {
        var p = try make(range: 0...1)
        p.assign(try LiveMIDIAddress(kind: .control, channel: 0, number: 1))
        p.setSource(.motion(.roll)); p.setAutomation(on: true)
        XCTAssertEqual(p.receive(cc(1, 127), takeover: .jump), .ignored)
        XCTAssertEqual(p.value, 0)
        p.setAutomation(on: false)
        p.setAmount(0.25)
        guard case .applied(let lifted) = p.receive(cc(1, 64), takeover: .jump) else { return XCTFail() }
        XCTAssertGreaterThan(lifted, 64.0 / 127, "a low amount lifts the response")
        p.setAmount(0.5)
        XCTAssertEqual(p.receive(cc(1, 127), takeover: .jump), .applied(1))
        p.beginLearning(); p.cancelLearning()
        XCTAssertEqual(p.midiState, .assigned)
    }

    // MARK: Presentation and saving

    func testValueText() {
        XCTAssertEqual(LiveValueFormat.text(0.5), "0.50000")
        XCTAssertEqual(LiveValueFormat.text(12.345678), "12.3456", "cut, not rounded")
        XCTAssertEqual(LiveValueFormat.text(-0.5), "-0.5000")
        XCTAssertEqual(LiveValueFormat.text(-0.000001), "-0.0000", "printf keeps the sign of a tiny negative")
        XCTAssertEqual(LiveValueFormat.text(99999.5), "99999.5")
        XCTAssertEqual(LiveValueFormat.text(123456.7), "123456")
        XCTAssertEqual(LiveValueFormat.text(.infinity), "—")
        XCTAssertEqual(LiveValueFormat.text(.nan), "—")
    }

    func testCodableKeepsSettingsAndDropsRuntimeState() throws {
        var p = try LiveParameterState(id: LiveObjectID(rawValue: "cut"), label: "Cutoff", value: 3,
                                  mapping: LiveValueMapping(range: 0...10, limit: 1...9, step: 0.5))
        p.setDefaultValue(5); p.setManualValue(4)
        p.setSource(.audio(.high)); p.setAutomation(on: true); p.setInverse(true); p.setAmount(0.7)
        p.setLFO(try LiveLFO(period: .seconds(3), phase: 0.25)); p.setWave(LiveWave(shape: .noise, seed: 5))
        p.setAudioEnvelope(attack: 0.05, release: 0.4)
        p.setPaceReference(LiveObjectID(rawValue: "pace"))
        p.assign(try LiveMIDIAddress(kind: .control, channel: 3, number: 20))
        p.beginLearning()
        p.tick(LiveTick(deltaTime: 0.5, sourceValue: 1))
        let decoded = try JSONDecoder().decode(LiveParameterState.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.id, p.id); XCTAssertEqual(decoded.label, "Cutoff")
        XCTAssertEqual(decoded.mapping, p.mapping)
        XCTAssertEqual(decoded.defaultValue, 5); XCTAssertEqual(decoded.value, p.value)
        XCTAssertEqual(decoded.source, .audio(.high)); XCTAssertTrue(decoded.automationIsOn); XCTAssertTrue(decoded.inverse)
        XCTAssertEqual(decoded.amount, 0.7)
        XCTAssertEqual(decoded.lfo, p.lfo); XCTAssertEqual(decoded.wave, p.wave)
        XCTAssertEqual(decoded.audioEnvelope.attack, 0.05); XCTAssertEqual(decoded.audioEnvelope.release, 0.4)
        XCTAssertEqual(decoded.paceReference, p.paceReference); XCTAssertNil(decoded.pulseWidthReference)
        XCTAssertEqual(decoded.midiAddresses, p.midiAddresses)
        XCTAssertFalse(decoded.isLearning, "learning is not saved")
        XCTAssertEqual(decoded.smoothedValue, decoded.value, "smoothing restarts at the value")
    }

    func testDecodingFillsDefaultsAndRefusesBadData() throws {
        let minimal = #"{"id":"a","mapping":{"range":[0,1]},"value":9}"#
        let p = try JSONDecoder().decode(LiveParameterState.self, from: Data(minimal.utf8))
        XCTAssertEqual(p.value, 1); XCTAssertEqual(p.defaultValue, 1); XCTAssertNil(p.source)
        XCTAssertFalse(p.isAutomated); XCTAssertEqual(p.amount, 0.5); XCTAssertEqual(p.label, "")
        let badAddress = #"{"id":"a","mapping":{"range":[0,1]},"value":0,"midiAddresses":[{"kind":"note","channel":16,"number":0}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(LiveParameterState.self, from: Data(badAddress.utf8)))
        let badRange = #"{"id":"a","mapping":{"range":[1,0]},"value":0}"#
        XCTAssertThrowsError(try JSONDecoder().decode(LiveParameterState.self, from: Data(badRange.utf8)))
    }

    /// The integer-arithmetic text must match what `%.5f` gives, for every kind of value.
    func testValueTextMatchesPrintf() {
        func expected(_ v: Double) -> String {
            if v >= 100_000 { return String(Int64(v)) }
            return String(String(format: "%.5f", v).prefix(7))
        }
        var rng = SystemRandomNumberGenerator()
        var samples: [Double] = [0, 0.5, 0.000005, 0.000015, 0.999995, 9.999995, 99.99999, 99999.99999, 1, -1, -0.0, 0.1, 0.2, 0.3, 1.23456789]
        for _ in 0..<200_000 {
            samples.append(Double.random(in: -200_000...200_000, using: &rng))
            samples.append(Double.random(in: 0...1, using: &rng))
            samples.append(Double(Int.random(in: 0...2_000_000, using: &rng)) / 100_000)   // ties and near-ties
        }
        for v in samples where v.isFinite {
            XCTAssertEqual(LiveValueFormat.text(v), expected(v), "\(v)")
        }
    }

    // MARK: Settings

    func testApplyingSettingsSetsUpAFreshParameterAndLeavesItsValueAndPhaseAlone() throws {
        var source = try make(range: -10...10, value: 3)
        source.setSource(.lfo); source.setAutomation(on: true); source.setInverse(true); source.setAmount(0.3)
        source.setLFO(try LiveLFO(period: .seconds(2), phase: 0.25)); source.setWave(LiveWave(shape: .tri, seed: 1))
        source.assign(try LiveMIDIAddress(kind: .control, channel: 1, number: 7))
        let settings = LiveParameterSnapshot(source)

        var target = try make(range: 0...10, value: 3)
        target.apply(settings: settings)
        XCTAssertTrue(LiveParameterSnapshot(target).hasSameSettings(as: settings))
        XCTAssertEqual(target.value, 3)                                   // the value is the hand's, not the settings'

        // Running, then applying the same settings again changes nothing: the LFO keeps its place.
        target.tick(LiveTick(deltaTime: 0.7, bpm: 120, pace: 1, pulseWidth: nil, sourceValue: nil))
        let running = target.value
        target.apply(settings: settings)
        XCTAssertEqual(target.value, running)
        target.tick(LiveTick(deltaTime: 0.1, bpm: 120, pace: 1, pulseWidth: nil, sourceValue: nil))
        XCTAssertNotEqual(target.value, running)
    }

    func testSettingsThatDifferOnlyInValueAreTheSame() throws {
        var a = try make(value: 2), b = try make(value: 2)
        a.setSource(.lfo); b.setSource(.lfo); b.setManualValue(8)
        XCTAssertTrue(LiveParameterSnapshot(a).hasSameSettings(as: LiveParameterSnapshot(b)))
        b.setAmount(0.9)
        XCTAssertFalse(LiveParameterSnapshot(a).hasSameSettings(as: LiveParameterSnapshot(b)))
    }
}
