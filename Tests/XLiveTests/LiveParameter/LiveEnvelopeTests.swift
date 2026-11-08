import XCTest
import XLive

final class LiveEnvelopeTests: XCTestCase {
    func testFollowsWithSeparateRiseAndFall() {
        var e = LiveEnvelope(attack: 0.1, release: 1)
        e.process(1, deltaTime: 0.1)
        XCTAssertEqual(e.value, 1 - exp(-1), accuracy: 1e-12)
        let top = e.value
        e.process(0, deltaTime: 1)
        XCTAssertEqual(e.value, top * exp(-1), accuracy: 1e-12)
    }

    func testResultDoesNotDependOnStepSize() {
        var coarse = LiveEnvelope(attack: 0.3, release: 0.3)
        var fine = coarse
        coarse.process(1, deltaTime: 0.5)
        for _ in 0..<500 { fine.process(1, deltaTime: 0.001) }
        XCTAssertEqual(coarse.value, fine.value, accuracy: 1e-9)
    }

    func testZeroTimeIsInstantAndInfiniteNeverMoves() {
        var instant = LiveEnvelope(attack: 0, release: 0)
        XCTAssertEqual(instant.process(0.7, deltaTime: 0.001), 0.7)
        var frozen = LiveEnvelope(attack: .infinity, release: 0.1, initial: 0.2)
        XCTAssertEqual(frozen.process(1, deltaTime: 10), 0.2)
        XCTAssertGreaterThan(LiveEnvelope(attack: 1, release: 0).attack, 0)
    }

    func testBadInputLeavesTheValue() {
        var e = LiveEnvelope(attack: 0.1, release: 0.1, initial: 0.4)
        for (target, dt) in [(Double.nan, 0.1), (1, .nan), (1, 0), (1, -1), (.infinity, 0.1)] {
            XCTAssertEqual(e.process(target, deltaTime: dt), 0.4)
        }
    }

    func testPerFrameConversionMatchesTheOldFollower() {
        var e = LiveEnvelope(perFrameRise: 0.3, fall: 0.1)
        var old = 0.0
        for _ in 0..<10 { old += (1 - old) * 0.3; e.process(1, deltaTime: 1.0 / 60) }
        XCTAssertEqual(e.value, old, accuracy: 1e-9)
        for _ in 0..<10 { old += (0 - old) * 0.1; e.process(0, deltaTime: 1.0 / 60) }
        XCTAssertEqual(e.value, old, accuracy: 1e-9)
        XCTAssertEqual(LiveEnvelope.timeConstant(perFrame: 1, frameRate: 60), 0)
        XCTAssertEqual(LiveEnvelope.timeConstant(perFrame: 0, frameRate: 60), .infinity)
    }
}
