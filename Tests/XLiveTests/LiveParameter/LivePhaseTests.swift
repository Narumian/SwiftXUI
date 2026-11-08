import XCTest
import XLive

final class LivePhaseTests: XCTestCase {
    func testAdvanceWrapsAndHoldsOnBadInput() {
        var phase = LivePhase()
        phase.advance(seconds: 0.75, cyclesPerSecond: 1)
        XCTAssertEqual(phase.cycles, 0.75, accuracy: 1e-12)
        phase.advance(seconds: 0.5, cyclesPerSecond: 1)
        XCTAssertEqual(phase.cycles, 0.25, accuracy: 1e-12)
        let held = phase
        phase.advance(seconds: -1, cyclesPerSecond: 1)
        phase.advance(seconds: .nan, cyclesPerSecond: 1)
        phase.advance(seconds: 1, cyclesPerSecond: .infinity)
        XCTAssertEqual(phase, held)
        phase.advance(seconds: 1, cyclesPerSecond: -0.5)  // running backwards stays in range
        XCTAssertEqual(phase.cycles, 0.75, accuracy: 1e-12)
    }

    func testBeatPeriodFollowsTempo() {
        var phase = LivePhase()
        phase.advance(seconds: 1, period: .beats(4), bpm: 120)   // 2 beats of 4
        XCTAssertEqual(phase.cycles, 0.5, accuracy: 1e-12)
        phase.advance(seconds: 1, period: .beats(4), bpm: nil)   // no tempo: hold
        phase.advance(seconds: 1, period: .beats(4), bpm: 0)
        XCTAssertEqual(phase.cycles, 0.5, accuracy: 1e-12)
        phase.advance(seconds: 1, period: .seconds(4), bpm: nil)
        XCTAssertEqual(phase.cycles, 0.75, accuracy: 1e-12)
    }

    func testChangingPaceDoesNotJumpThePosition() {
        var phase = LivePhase()
        phase.advance(seconds: 1, period: .seconds(4), bpm: nil, pace: 1)
        let before = phase.cycles
        phase.advance(seconds: 0, period: .seconds(4), bpm: nil, pace: 8)
        XCTAssertEqual(phase.cycles, before)
        phase.advance(seconds: 1, period: .seconds(4), bpm: nil, pace: 2)
        XCTAssertEqual(phase.cycles, before + 0.5, accuracy: 1e-12)
    }

    func testCodableIsASingleNumber() throws {
        let data = try JSONEncoder().encode(LivePhase(cycles: 1.25))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "0.25")
        XCTAssertEqual(try JSONDecoder().decode(LivePhase.self, from: data), LivePhase(cycles: 0.25))
    }
}
