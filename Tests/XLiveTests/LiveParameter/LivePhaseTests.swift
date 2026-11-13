import XCTest
import XLive

final class LivePhaseTests: XCTestCase {
    func testAdvanceWrapsAndHoldsOnBadInput() {
        var phase = LivePhase()
        phase.advance(seconds: 0.75, cyclesPerSecond: 1)
        XCTAssertEqual(phase.cycles, 0.75, accuracy: 1e-12)
        XCTAssertEqual(phase.cycleIndex, 0)
        phase.advance(seconds: 0.5, cyclesPerSecond: 1)
        XCTAssertEqual(phase.cycles, 0.25, accuracy: 1e-12)
        XCTAssertEqual(phase.cycleIndex, 1)
        let held = phase
        phase.advance(seconds: -1, cyclesPerSecond: 1)
        phase.advance(seconds: .nan, cyclesPerSecond: 1)
        phase.advance(seconds: 1, cyclesPerSecond: .infinity)
        XCTAssertEqual(phase, held)
        phase.advance(seconds: 1, cyclesPerSecond: -0.5)  // running backwards stays in range
        XCTAssertEqual(phase.cycles, 0.75, accuracy: 1e-12)
        XCTAssertEqual(phase.cycleIndex, 0)
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

    func testCodablePreservesCycleIndexAndReadsLegacyScalar() throws {
        let data = try JSONEncoder().encode(LivePhase(cycles: 1.25))
        var phase = LivePhase()
        phase.advance(seconds: 3.25, cyclesPerSecond: 1)
        let fullData = try JSONEncoder().encode(phase)
        XCTAssertEqual(try JSONDecoder().decode(LivePhase.self, from: fullData), phase)
        XCTAssertEqual(try JSONDecoder().decode(LivePhase.self, from: Data("0.25".utf8)), LivePhase(cycles: 0.25))
        XCTAssertEqual(try JSONDecoder().decode(LivePhase.self, from: data), LivePhase(cycles: 0.25))
    }

    func testPositionOffsetCarriesAcrossCycleBoundary() {
        var phase = LivePhase()
        phase.advance(seconds: 0.8, cyclesPerSecond: 1)
        let position = phase.position(adding: 0.4)
        XCTAssertEqual(position.cycleIndex, 1)
        XCTAssertEqual(position.fraction, 0.2, accuracy: 1e-12)
        let negativeOffset = phase.position(adding: -1.1)
        XCTAssertEqual(negativeOffset.cycleIndex, -1)
        XCTAssertEqual(negativeOffset.fraction, 0.7, accuracy: 1e-12)
    }
}
