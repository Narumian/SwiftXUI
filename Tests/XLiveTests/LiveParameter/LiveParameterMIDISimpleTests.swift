import XCTest
import XLive

final class LiveParameterMIDISimpleTests: XCTestCase {
    private func cc(_ number: UInt8, _ value: UInt8, channel: UInt8 = 0) -> MIDIMessage {
        .controlChange(channel: channel, controller: number, value: value)
    }

    func testFollowsItsControllerAndIgnoresOthers() throws {
        var p = try LiveParameterMIDISimple(value: 0, mapping: LiveValueMapping(range: 0...10),
                                            address: LiveMIDIAddress(kind: .control, channel: 2, number: 74))
        XCTAssertEqual(p.receive(cc(74, 127, channel: 2)), .applied(10))
        XCTAssertEqual(p.value, 10)
        XCTAssertEqual(p.origin, .midi)
        XCTAssertEqual(p.receive(cc(74, 0, channel: 2)), .applied(0))
        for other in [cc(75, 64, channel: 2), cc(74, 64, channel: 3), .noteOn(channel: 2, note: 74, velocity: 90)] {
            XCTAssertEqual(p.receive(other), .ignored)
        }
        XCTAssertEqual(p.value, 0)
        XCTAssertEqual(p.receive(cc(74, 64, channel: 2)), .applied(10 * 64.0 / 127))
    }

    func testUnboundParameterIgnoresEverything() throws {
        var p = try LiveParameterMIDISimple(value: 0.3)
        XCTAssertEqual(p.receive(cc(1, 127)), .ignored)
        XCTAssertEqual(p.value, 0.3)
    }

    func testNotesCarryVelocityAndReleaseToZero() throws {
        var p = try LiveParameterMIDISimple(value: 0, address: LiveMIDIAddress(kind: .note, channel: 9, number: 36))
        XCTAssertEqual(p.receive(.noteOn(channel: 9, note: 36, velocity: 127)), .applied(1))
        XCTAssertEqual(p.receive(.noteOff(channel: 9, note: 36, velocity: 64)), .applied(0))
        XCTAssertEqual(p.receive(.noteOn(channel: 9, note: 36, velocity: 0)), .applied(0), "velocity 0 is a release")
        XCTAssertEqual(p.receive(.noteOff(channel: 9, note: 37, velocity: 0)), .ignored)
    }

    func testLearningBindsTheFirstLearnableMessageWithoutApplyingIt() throws {
        var p = try LiveParameterMIDISimple(value: 0.5)
        p.beginLearning()
        XCTAssertTrue(p.isLearning)
        XCTAssertEqual(p.receive(.noteOff(channel: 0, note: 60, velocity: 0)), .ignored, "a release is not learnable")
        XCTAssertEqual(p.receive(.noteOn(channel: 0, note: 60, velocity: 0)), .ignored)
        XCTAssertTrue(p.isLearning)
        let learned = try LiveMIDIAddress(kind: .control, channel: 1, number: 7)
        XCTAssertEqual(p.receive(cc(7, 100, channel: 1)), .learned(learned))
        XCTAssertFalse(p.isLearning)
        XCTAssertEqual(p.address, learned)
        XCTAssertEqual(p.value, 0.5, "the learning message does not move the value")
        XCTAssertEqual(p.origin, .initial)
        XCTAssertEqual(p.receive(cc(7, 127, channel: 1)), .applied(1))
    }

    func testBindAndCancelLeaveLearning() throws {
        var p = try LiveParameterMIDISimple(value: 0)
        p.beginLearning(); p.cancelLearning()
        XCTAssertFalse(p.isLearning)
        p.beginLearning(); p.bind(try LiveMIDIAddress(kind: .control, channel: 0, number: 1))
        XCTAssertFalse(p.isLearning)
        p.bind(nil)
        XCTAssertEqual(p.receive(cc(1, 127)), .ignored)
    }

    func testLatestWriterWinsBetweenHandAndMIDI() throws {
        var p = try LiveParameterMIDISimple(value: 0, address: LiveMIDIAddress(kind: .control, channel: 0, number: 1))
        p.receive(cc(1, 127))
        p.setNormalizedManualValue(0.25)
        XCTAssertEqual(p.value, 0.25); XCTAssertEqual(p.origin, .manual)
        p.receive(cc(1, 127))
        XCTAssertEqual(p.value, 1); XCTAssertEqual(p.origin, .midi)
        p.setManualValue(.nan); p.setNormalizedManualValue(.infinity)
        XCTAssertEqual(p.value, 1); XCTAssertEqual(p.origin, .midi, "non-finite input changes nothing")
        p.setManualValue(5)
        XCTAssertEqual(p.value, 1, "clamped to the range")
    }

    func testStepCurveAndLimitApplyToMIDI() throws {
        var stepped = try LiveParameterMIDISimple(value: 0, mapping: LiveValueMapping(range: 0...10, step: 5),
                                                  address: LiveMIDIAddress(kind: .control, channel: 0, number: 1))
        stepped.receive(cc(1, 60)); XCTAssertEqual(stepped.value, 5)
        stepped.receive(cc(1, 20)); XCTAssertEqual(stepped.value, 0)
        var limited = try LiveParameterMIDISimple(value: 50, mapping: LiveValueMapping(range: 0...100, limit: 20...80),
                                                  address: LiveMIDIAddress(kind: .control, channel: 0, number: 1))
        limited.receive(cc(1, 127)); XCTAssertEqual(limited.value, 80)
        limited.receive(cc(1, 0)); XCTAssertEqual(limited.value, 20)
        var lifted = try LiveParameterMIDISimple(value: 0, address: LiveMIDIAddress(kind: .control, channel: 0, number: 1), curve: 0.25)
        lifted.receive(cc(1, 64))
        XCTAssertGreaterThan(lifted.value, 64.0 / 127)
    }

    func testValidation() throws {
        XCTAssertThrowsError(try LiveMIDIAddress(kind: .control, channel: 16, number: 0))
        XCTAssertThrowsError(try LiveMIDIAddress(kind: .note, channel: 0, number: 128))
        XCTAssertThrowsError(try LiveParameterMIDISimple(value: .nan))
        XCTAssertThrowsError(try LiveParameterMIDISimple(value: 0, curve: .nan))
        XCTAssertEqual(try LiveParameterMIDISimple(value: 7).value, 1, "clamped into the range")
        XCTAssertEqual(try LiveParameterMIDISimple(value: 0, curve: 9).curve, 1)
    }

    func testCodableKeepsStateButNotLearning() throws {
        var p = try LiveParameterMIDISimple(value: 3, mapping: LiveValueMapping(range: 0...10, limit: 1...9, step: 0.5),
                                            address: LiveMIDIAddress(kind: .note, channel: 4, number: 60), curve: 0.7)
        p.setManualValue(4)
        p.beginLearning()
        let decoded = try JSONDecoder().decode(LiveParameterMIDISimple.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.value, 4)
        XCTAssertEqual(decoded.mapping, p.mapping)
        XCTAssertEqual(decoded.address, p.address)
        XCTAssertEqual(decoded.curve, 0.7)
        XCTAssertEqual(decoded.origin, .manual)
        XCTAssertFalse(decoded.isLearning)
        let bad = #"{"value":0,"mapping":{"range":[0,1]},"address":{"kind":"control","channel":16,"number":0}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(LiveParameterMIDISimple.self, from: Data(bad.utf8)))
        let minimal = #"{"value":9,"mapping":{"range":[0,1]}}"#
        let clamped = try JSONDecoder().decode(LiveParameterMIDISimple.self, from: Data(minimal.utf8))
        XCTAssertEqual(clamped.value, 1); XCTAssertNil(clamped.address); XCTAssertEqual(clamped.curve, 0.5)
    }

    func testAddressDescriptorBridge() throws {
        XCTAssertEqual(try LiveMIDIAddress(kind: .control, channel: 1, number: 7).descriptor, .midiControl(channel: 1, controller: 7))
        XCTAssertEqual(try LiveMIDIAddress(kind: .note, channel: 9, number: 36).descriptor, .midiNote(channel: 9, note: 36))
    }
}
