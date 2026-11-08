import XCTest
import XLive
import XCombine

final class LiveParameterHostTests: XCTestCase {
    private func state(_ id: String, range: ClosedRange<Double> = 0...10, value: Double = 0) throws -> LiveParameterState {
        try LiveParameterState(id: LiveObjectID(rawValue: id), label: id, value: value, mapping: LiveValueMapping(range: range))
    }

    func testFramesDriveAnLFOAndNothingRunsWithoutThem() throws {
        let host = LiveParameterHost(bpm: 120)
        let p = host.add(try state("lfo"))
        p.edit {
            $0.setSource(.lfo); $0.setAutomation(on: true)
            $0.setLFO(try! LiveLFO(period: .beats(4))); $0.setWave(LiveWave(shape: .saw))
        }
        host.advance(seconds: 1)            // 2 of 4 beats
        XCTAssertEqual(p.value, 5, accuracy: 1e-9)
        host.advance(seconds: -1); host.advance(seconds: .nan)
        XCTAssertEqual(p.value, 5)
        host.bpm = nil
        host.advance(seconds: 1)
        XCTAssertEqual(p.value, 5, "no tempo holds the LFO")
    }

    func testMIDIAndSourcesAndReferences() throws {
        let host = LiveParameterHost()
        let level = XPassthroughSubject<Double, Never>()
        host.provide(.motion(.roll), level.eraseToAnyPublisher())
        let pace = host.add(try state("pace", range: 0...4, value: 2))
        XCTAssertTrue(host.parameter(withID: pace.id) === pace)

        let p = host.add(try state("p"))
        p.edit { $0.assign(try! LiveMIDIAddress(kind: .control, channel: 0, number: 5)) }
        host.send(.controlChange(channel: 0, controller: 5, value: 127))
        XCTAssertEqual(p.value, 10)

        p.edit { $0.setSource(.motion(.roll)); $0.setAutomation(on: true) }
        level.send(0.3)
        host.advance(seconds: 0.01)
        XCTAssertEqual(p.value, 3, accuracy: 1e-9)

        p.edit { $0.setSource(.lfo); $0.setLFO(try! LiveLFO(period: .seconds(4))); $0.setWave(LiveWave(shape: .saw)); $0.setPaceReference(pace.id) }
        host.advance(seconds: 1)
        XCTAssertEqual(p.value, 5, accuracy: 1e-9, "pace 2 doubles the quarter cycle")
    }

    func testRemoveAndReplace() throws {
        let host = LiveParameterHost()
        let first = host.add(try state("a", value: 1))
        let second = host.add(try state("a", value: 2))
        XCTAssertTrue(host.parameter(withID: first.id) === second)
        XCTAssertEqual(host.parameters.count, 1)
        host.remove(second.id)
        XCTAssertNil(host.parameter(withID: second.id))
        XCTAssertEqual(host.parameters.count, 0)
    }

    // MARK: MIDI routing

    private func address(_ number: UInt8, kind: LiveMIDIAddress.Kind = .control, channel: UInt8 = 0) -> LiveMIDIAddress {
        try! LiveMIDIAddress(kind: kind, channel: channel, number: number)
    }

    func testMessagesReachOnlyTheParametersThatFollowTheirControl() throws {
        let host = LiveParameterHost()
        let a = host.add(try state("a")), b = host.add(try state("b")), c = host.add(try state("c"))
        a.edit { $0.assign(address(1)) }
        b.edit { $0.assign(address(1)); $0.assign(address(2)) }
        c.edit { $0.assign(address(3)) }
        host.send(.controlChange(channel: 0, controller: 1, value: 127))
        XCTAssertEqual([a.value, b.value, c.value], [10, 10, 0], "two parameters may follow one control")
        host.send(.controlChange(channel: 0, controller: 2, value: 0))
        XCTAssertEqual([a.value, b.value, c.value], [10, 0, 0])
        host.send(.controlChange(channel: 5, controller: 3, value: 127))   // same number, other channel
        host.send(.noteOn(channel: 0, note: 3, velocity: 127))              // same number, other kind
        XCTAssertEqual(c.value, 0)
    }

    func testANoteAddressFollowsNoteOnAndNoteOff() throws {
        let host = LiveParameterHost()
        let p = host.add(try state("p"))
        p.edit { $0.assign(address(60, kind: .note)) }
        host.send(.noteOn(channel: 0, note: 60, velocity: 127))
        XCTAssertEqual(p.value, 10)
        host.send(.noteOff(channel: 0, note: 60, velocity: 0))
        XCTAssertEqual(p.value, 0)
    }

    func testLearningTakesTheMessageWithoutApplyingItThenFollowsTheControl() throws {
        let host = LiveParameterHost()
        let p = host.add(try state("p"))
        p.toggleLearning()
        host.send(.controlChange(channel: 0, controller: 9, value: 127))
        XCTAssertEqual(p.state.midiAddresses, [address(9)])
        XCTAssertEqual(p.value, 0, "the message that taught it is not applied")
        host.send(.controlChange(channel: 0, controller: 9, value: 127))
        XCTAssertEqual(p.value, 10)

        // Learning a second control while following the first: the first control's message
        // during learning teaches rather than applies.
        p.toggleLearning()
        host.send(.controlChange(channel: 0, controller: 9, value: 0))
        XCTAssertEqual(p.value, 10)
        XCTAssertEqual(p.state.midiAddresses, [address(9)], "already known, nothing new")
        XCTAssertFalse(p.state.isLearning)
        host.send(.controlChange(channel: 0, controller: 9, value: 0))
        XCTAssertEqual(p.value, 0)
    }

    func testChangingAddressesChangesTheRoute() throws {
        let host = LiveParameterHost()
        let p = host.add(try state("p"))
        p.edit { $0.assign(address(1)) }
        p.edit { $0.unassign(address(1)); $0.assign(address(2)) }
        host.send(.controlChange(channel: 0, controller: 1, value: 127))
        XCTAssertEqual(p.value, 0)
        host.send(.controlChange(channel: 0, controller: 2, value: 127))
        XCTAssertEqual(p.value, 10)
        p.edit { $0.clearMIDI() }
        host.send(.controlChange(channel: 0, controller: 2, value: 0))
        XCTAssertEqual(p.value, 10, "no address, no route")
    }

    func testAutomationIgnoresMIDIAndMIDIComesBackWhenItStops() throws {
        let host = LiveParameterHost()
        let p = host.add(try state("p"))
        p.edit { $0.assign(address(1)); $0.setSource(.lfo); $0.setAutomation(on: true) }
        host.send(.controlChange(channel: 0, controller: 1, value: 127))
        XCTAssertEqual(p.value, 0)
        p.edit { $0.setAutomation(on: false) }
        host.send(.controlChange(channel: 0, controller: 1, value: 127))
        XCTAssertEqual(p.value, 10)
    }

    func testAHostWithoutRoutesStillWorksThroughTheWholeStream() throws {
        final class Plain: LiveParameterEnvironment {
            let subject = XPassthroughSubject<MIDIMessage, Never>()
            let clockSubject = XPassthroughSubject<LiveClockTick, Never>()
            var clock: XAnyPublisher<LiveClockTick, Never> { clockSubject.eraseToAnyPublisher() }
            var midi: XAnyPublisher<MIDIMessage, Never> { subject.eraseToAnyPublisher() }
        }
        let plain = Plain()
        let p = LiveParameter(state: try state("p"), environment: plain)
        p.edit { $0.assign(address(4)) }
        plain.subject.send(.controlChange(channel: 0, controller: 4, value: 127))
        XCTAssertEqual(p.value, 10)
        plain.subject.send(.controlChange(channel: 0, controller: 5, value: 0))
        XCTAssertEqual(p.value, 10)
    }
}
