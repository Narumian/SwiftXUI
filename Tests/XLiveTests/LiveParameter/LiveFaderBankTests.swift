import XCTest
import XCombine
@testable import XLive

final class LiveFaderBankTests: XCTestCase {
    private func address(_ number: UInt8, kind: LiveMIDIAddress.Kind = .control) -> LiveMIDIAddress {
        try! LiveMIDIAddress(kind: kind, channel: 0, number: number)
    }
    private func cc(_ number: UInt8, _ value: UInt8) -> MIDIMessage { .controlChange(channel: 0, controller: number, value: value) }

    /// A host, a bank of two faders on controllers 1 and 2, and two 0...10 parameters at 5 and 5.
    private func make(mode: LiveTakeoverMode = .pickup) throws -> (LiveParameterHost, LiveFaderBank, LiveParameter, LiveParameter) {
        let host = LiveParameterHost()
        host.midiTakeover = mode
        let a = host.add(try LiveParameterState(value: 5, mapping: LiveValueMapping(range: 0...10)))
        let b = host.add(try LiveParameterState(value: 5, mapping: LiveValueMapping(range: 0...10)))
        let bank = LiveFaderBank(count: 2, environment: host)
        bank.assign(address(1), to: 0); bank.assign(address(2), to: 1)
        bank.setTargets([a, b])
        return (host, bank, a, b)
    }

    func testAFaderMustReachTheValueBeforeItMovesTheTarget() throws {
        let (host, bank, a, _) = try make()
        host.send(cc(1, 0))
        XCTAssertEqual(a.value, 5)
        XCTAssertTrue(bank.isWaiting(0))
        host.send(cc(1, 64))
        XCTAssertEqual(a.value, 64.0 / 127 * 10, accuracy: 1e-9)
        XCTAssertFalse(bank.isWaiting(0))
        host.send(cc(1, 127))
        XCTAssertEqual(a.value, 10, accuracy: 1e-9)
    }

    func testEachFaderDrivesItsOwnSlot() throws {
        let (host, bank, a, b) = try make(mode: .jump)
        host.send(cc(2, 127))
        XCTAssertEqual(a.value, 5)
        XCTAssertEqual(b.value, 10, accuracy: 1e-9)
        XCTAssertEqual(bank.controlPosition(1), 1)
        XCTAssertNil(bank.controlPosition(0))
    }

    func testJumpModeMovesTheTargetAtOnce() throws {
        let (host, bank, a, _) = try make(mode: .jump)
        host.send(cc(1, 0))
        XCTAssertEqual(a.value, 0)
        XCTAssertEqual(bank.addresses[0], address(1), "the bank is kept alive by the test")
    }

    func testChangingTheTargetRequiresPickupAgain() throws {
        let (host, bank, a, b) = try make()
        host.send(cc(1, 64)); host.send(cc(1, 127))        // engaged, at the top
        XCTAssertEqual(a.value, 10, accuracy: 1e-9)
        bank.setTargets([b, nil])                          // slot 0 now drives b, at 5
        host.send(cc(1, 120))
        XCTAssertEqual(b.value, 5, "the fader is far from b's value and does not move it")
        XCTAssertEqual(a.value, 10, accuracy: 1e-9, "the old target is let go")
        host.send(cc(1, 10))                               // crosses b's value on the way down
        XCTAssertEqual(b.value, 10.0 / 127 * 10, accuracy: 1e-9)
    }

    func testKeepingTheSameTargetKeepsTheFaderEngaged() throws {
        let (host, bank, a, b) = try make()
        host.send(cc(1, 64)); host.send(cc(1, 127))
        bank.setTargets([a, b])
        host.send(cc(1, 0))
        XCTAssertEqual(a.value, 0)
    }

    func testAnotherWriteToTheTargetReleasesTheFader() throws {
        let (host, bank, a, _) = try make()
        host.send(cc(1, 64)); host.send(cc(1, 100))
        a.setManualValue(1)                                // a hand on the slider
        host.send(cc(1, 110))
        XCTAssertEqual(a.value, 1)
        XCTAssertTrue(bank.isWaiting(0))
        host.send(cc(1, 0))                                // crosses it
        XCTAssertEqual(a.value, 0)
    }

    func testAnAutomatedTargetIsLocked() throws {
        let (host, bank, a, _) = try make(mode: .jump)
        a.edit { $0.setSource(.lfo); $0.setAutomation(on: true) }
        XCTAssertTrue(bank.isLocked(0))
        let before = a.value
        XCTAssertEqual(bank.receive(cc(1, 0)), .locked(slot: 0))
        host.send(cc(1, 0))
        XCTAssertEqual(a.value, before)
        XCTAssertFalse(bank.isLocked(1))
    }

    func testTheOnScreenFaderSetsTheValueAndReleasesTheController() throws {
        let (host, bank, a, _) = try make()
        host.send(cc(1, 64)); host.send(cc(1, 100))
        bank.move(0, to: 0.2)
        XCTAssertEqual(a.value, 2, accuracy: 1e-9)
        host.send(cc(1, 110))
        XCTAssertEqual(a.value, 2, accuracy: 1e-9, "the controller has to come back to the value")
        bank.move(0, to: 7)                                // clamped
        XCTAssertEqual(a.value, 10, accuracy: 1e-9)
        bank.move(5, to: 0.5); bank.move(1, to: .nan)      // out of range, not finite
    }

    func testASlotWithoutATargetDoesNothingButKeepsThePosition() throws {
        let (host, bank, _, b) = try make()
        bank.setTargets([nil, nil])
        XCTAssertEqual(bank.receive(cc(1, 30)), .ignored)
        XCTAssertEqual(bank.controlPosition(0) ?? 0, 30.0 / 127, accuracy: 1e-9)
        bank.setTargets([nil, b])
        host.send(cc(2, 64))
        XCTAssertEqual(b.value, 64.0 / 127 * 10, accuracy: 1e-9)
    }

    func testLearningTakesTheNextControllerAndOnlyControllers() throws {
        let host = LiveParameterHost()
        let bank = LiveFaderBank(count: 2, environment: host)
        bank.beginLearning(1)
        XCTAssertEqual(bank.receive(.noteOn(channel: 0, note: 60, velocity: 100)), .ignored)
        XCTAssertEqual(bank.learningSlot, 1)
        host.send(cc(9, 10))
        XCTAssertEqual(bank.addresses, [nil, address(9)])
        XCTAssertNil(bank.learningSlot)
        // The learned controller now routes to the bank.
        let p = host.add(try LiveParameterState(value: 0, mapping: LiveValueMapping(range: 0...1)))
        bank.setTargets([nil, p])
        host.send(cc(9, 0))
        XCTAssertEqual(p.value, 0)
        XCTAssertEqual(bank.controlPosition(1), 0)
    }

    func testAControllerBelongsToOneSlot() throws {
        let (_, bank, _, _) = try make()
        bank.assign(address(1), to: 1)
        XCTAssertEqual(bank.addresses, [nil, address(1)])
        bank.assign(address(5, kind: .note), to: 0)
        XCTAssertNil(bank.addresses[0], "a note is not a fader")
        bank.unassign(1)
        XCTAssertEqual(bank.addresses, [nil, nil])
    }

    func testUnassignedControllersAndOtherMessagesAreIgnored() throws {
        let (host, bank, a, _) = try make(mode: .jump)
        host.send(cc(77, 0))
        host.send(.noteOn(channel: 0, note: 1, velocity: 127))
        XCTAssertEqual(a.value, 5)
        XCTAssertEqual(bank.receive(cc(77, 0)), .ignored)
    }

    func testAHostWithoutRoutesIsFilteredByTheBank() throws {
        final class Plain: LiveParameterEnvironment {
            let subject = XPassthroughSubject<MIDIMessage, Never>()
            var clock: XAnyPublisher<LiveClockTick, Never> { XPassthroughSubject<LiveClockTick, Never>().eraseToAnyPublisher() }
            var midi: XAnyPublisher<MIDIMessage, Never> { subject.eraseToAnyPublisher() }
            var midiTakeover: LiveTakeoverMode { .jump }
        }
        let host = Plain()
        let p = LiveParameter(state: try LiveParameterState(value: 5, mapping: LiveValueMapping(range: 0...10)), environment: host)
        let bank = LiveFaderBank(count: 1, environment: host)
        bank.assign(address(1), to: 0); bank.setTargets([p])
        host.subject.send(cc(1, 127))
        XCTAssertEqual(p.value, 10, accuracy: 1e-9)
    }
}
