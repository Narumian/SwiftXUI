import XCTest
@testable import XLive

final class LiveTakeoverTests: XCTestCase {
    private func address(_ number: UInt8, kind: LiveMIDIAddress.Kind = .control) -> LiveMIDIAddress {
        try! LiveMIDIAddress(kind: kind, channel: 0, number: number)
    }
    private func cc(_ number: UInt8, _ value: UInt8) -> MIDIMessage {
        .controlChange(channel: 0, controller: number, value: value)
    }
    /// 0...10, at `value`, following controller 1.
    private func make(value: Double = 5, step: Double? = nil) throws -> LiveParameterState {
        var p = try LiveParameterState(value: value, mapping: LiveValueMapping(range: 0...10, step: step))
        p.assign(address(1))
        return p
    }

    // MARK: The value type

    func testAControlFarFromTheValueIsNotAcceptedUntilItIsOnTheValue() {
        var t = LiveTakeover()
        let a = address(1)
        XCTAssertFalse(t.accepts(0.1, from: a, current: 0.5))
        XCTAssertFalse(t.accepts(0.3, from: a, current: 0.5), "closer, but still on its own side")
        XCTAssertTrue(t.accepts(0.5 + LiveTakeover.tolerance / 2, from: a, current: 0.5))
    }

    func testCrossingTheValueBetweenTwoMessagesCountsAsReachingIt() {
        var t = LiveTakeover()
        let a = address(1)
        XCTAssertFalse(t.accepts(0.1, from: a, current: 0.5))
        XCTAssertTrue(t.accepts(0.9, from: a, current: 0.5), "a fast sweep jumps over the value")
    }

    func testTheFirstMessageHasNothingToCross() {
        var t = LiveTakeover()
        XCTAssertFalse(t.accepts(0.9, from: address(1), current: 0.5))
    }

    func testAnEngagedControlIsAlwaysAcceptedAndReleaseTakesItBack() {
        var t = LiveTakeover()
        let a = address(1)
        t.engage(a)
        XCTAssertTrue(t.accepts(0.0, from: a, current: 0.9))
        XCTAssertTrue(t.accepts(1.0, from: a, current: 0.2))
        t.release()
        XCTAssertNil(t.engaged)
        XCTAssertFalse(t.accepts(0.95, from: a, current: 0.9), "released: it has to come back to the value")
        XCTAssertTrue(t.accepts(0.3, from: a, current: 0.9), "and moving across it does that")
    }

    func testAnotherControlNeedsItsOwnPickup() {
        var t = LiveTakeover()
        let a = address(1), b = address(2)
        t.engage(a)
        XCTAssertFalse(t.accepts(0.9, from: b, current: 0.5), "b holds nothing yet")
        XCTAssertTrue(t.accepts(0.2, from: a, current: 0.5), "a still holds the value")
    }

    func testAPositionOfAnotherControlIsNotAStartingPointForCrossing() {
        var t = LiveTakeover()
        let a = address(1), b = address(2)
        XCTAssertFalse(t.accepts(0.1, from: a, current: 0.5))
        XCTAssertFalse(t.accepts(0.9, from: b, current: 0.5), "b was never on the other side")
    }

    // MARK: In a parameter's state

    func testAControllerWaitsThenTakesOverWhereItCrosses() throws {
        var p = try make()
        XCTAssertEqual(p.receive(cc(1, 10)), .waiting)
        XCTAssertEqual(p.value, 5)
        XCTAssertEqual(p.receive(cc(1, 40)), .waiting)
        XCTAssertEqual(p.value, 5)
        guard case .applied(let crossed) = p.receive(cc(1, 100)) else { return XCTFail("should have crossed the value") }
        XCTAssertEqual(crossed, 100.0 / 127 * 10, accuracy: 1e-9)
        XCTAssertEqual(p.receive(cc(1, 0)), .applied(0), "once it holds the value, the value follows it anywhere")
        XCTAssertEqual(p.value, 0)
    }

    func testAControllerAlreadyOnTheValueTakesOverAtOnce() throws {
        var p = try make()
        guard case .applied = p.receive(cc(1, 64)) else { return XCTFail() }   // 64/127 is within a step of 0.5
    }

    func testAnythingButTheControllerReleasesTheValue() throws {
        var p = try make()
        XCTAssertEqual(p.receive(cc(1, 64)), .applied(64.0 / 127 * 10))
        p.setManualValue(8)
        XCTAssertNil(p.takeover.engaged, "a hand wrote the value")
        XCTAssertEqual(p.receive(cc(1, 10)), .waiting)
        guard case .applied(let v) = p.receive(cc(1, 102)) else { return XCTFail("102/127 is within a step of 0.8") }
        XCTAssertEqual(v, 102.0 / 127 * 10, accuracy: 1e-9)

        p.setNormalizedManualValue(0.2)
        XCTAssertEqual(p.receive(cc(1, 127)), .waiting)
        p.reset()
        XCTAssertNil(p.takeover.engaged, "a reset glides the value, so the controller no longer holds it")
    }

    func testAutomationReleasesTheValueSoTheControllerPicksUpWhereAutomationLeftIt() throws {
        var p = try make(value: 0)
        XCTAssertEqual(p.receive(cc(1, 0)), .applied(0))
        p.setSource(.audio(.low)); p.setAutomation(on: true)
        p.tick(LiveTick(deltaTime: 0.01, sourceValue: 0.8))
        XCTAssertGreaterThan(p.value, 0)
        XCTAssertEqual(p.receive(cc(1, 0)), .ignored, "automation ignores MIDI")
        p.setAutomation(on: false)
        XCTAssertEqual(p.receive(cc(1, 0)), .waiting, "the value is where automation left it, not where the knob is")
    }

    func testJumpModeMovesTheValueAtOnceAndNotesAlwaysDo() throws {
        var p = try make()
        XCTAssertEqual(p.receive(cc(1, 127), takeover: .jump), .applied(10))

        var q = try make()
        q.assign(address(36, kind: .note))
        XCTAssertEqual(q.receive(.noteOn(channel: 0, note: 36, velocity: 127)), .applied(10), "a key is not a position")
        XCTAssertEqual(q.receive(.noteOff(channel: 0, note: 36, velocity: 0)), .applied(0))
    }

    func testASteppedValueAcceptsTheControllerWithinHalfAStep() throws {
        var p = try make(value: 5, step: 1)   // 0...10 in whole numbers: half a step is 0.05 of the range
        XCTAssertEqual(p.receive(cc(1, 10)), .waiting)
        guard case .applied(let v) = p.receive(cc(1, 69)) else { return XCTFail("69/127 is 0.543: within half a step of 0.5") }
        XCTAssertEqual(v, 5)
    }

    func testTwoControllersOnOneParameterEachNeedTheirOwnPickup() throws {
        var p = try make()
        p.assign(address(2))
        guard case .applied = p.receive(cc(1, 64)) else { return XCTFail() }
        XCTAssertEqual(p.receive(cc(2, 0)), .waiting, "controller 2 is nowhere near the value")
        XCTAssertEqual(p.value, 64.0 / 127 * 10, accuracy: 1e-9)
        guard case .applied = p.receive(cc(1, 20)) else { return XCTFail("controller 1 still holds it") }
    }

    func testThePickupStateIsNotSaved() throws {
        var p = try make()
        _ = p.receive(cc(1, 64))
        let copy = try JSONDecoder().decode(LiveParameterState.self, from: JSONEncoder().encode(p))
        XCTAssertNil(copy.takeover.engaged)
        XCTAssertNil(copy.takeover.position)
        XCTAssertEqual(copy.midiAddresses, p.midiAddresses)
    }

    // MARK: Through a host

    func testHostsDefaultToPickupAndCanBeSwitchedToJump() throws {
        let host = LiveParameterHost()
        let p = host.add(try make(value: 5))
        host.send(.controlChange(channel: 0, controller: 1, value: 0))
        XCTAssertEqual(p.value, 5, "the knob is far from the value")
        host.send(.controlChange(channel: 0, controller: 1, value: 127))
        XCTAssertEqual(p.value, 10, "it swept across the value, so it took over")

        host.midiTakeover = .jump
        p.setManualValue(3)
        host.send(.controlChange(channel: 0, controller: 1, value: 127))
        XCTAssertEqual(p.value, 10)
    }

    func testWaitingMessagesDoNotPublishAValue() throws {
        let host = LiveParameterHost()
        let p = host.add(try make(value: 5))
        var seen: [Double] = []
        let token = p.valuePublisher.sink { seen.append($0) }
        host.send(.controlChange(channel: 0, controller: 1, value: 5))
        host.send(.controlChange(channel: 0, controller: 1, value: 20))
        XCTAssertEqual(seen, [5], "only the value it started with")
        XCTAssertGreaterThan(p.state.takeover.position ?? 0, 0, "but the control's position is kept for display")
        withExtendedLifetime(token) {}
    }
}
