import XCTest
import XLive

final class LiveParameterLFOSimpleCodableTests: XCTestCase {
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func decode(_ json: String) throws -> LiveParameterLFOSimple {
        try JSONDecoder().decode(LiveParameterLFOSimple.self, from: Data(json.utf8))
    }

    func testAutomaticParameterKeepsItsPlaceInTheCycle() throws {
        var parameter = try LiveParameterLFOSimple(value: 0.5, range: 0...10, lfo: LiveLFO(period: .seconds(4), phase: 0.25))
        parameter.update(context: LiveUpdateContext(deltaTime: 1))
        var restored = try roundTrip(parameter)

        XCTAssertEqual(restored.value, parameter.value)
        XCTAssertEqual(restored.mode, .automatic)
        XCTAssertEqual(restored.lfo, parameter.lfo)
        XCTAssertEqual(restored.range, 0...10)

        // The cycle carries on from the same phase, not from the start.
        parameter.update(context: LiveUpdateContext(deltaTime: 0.7))
        restored.update(context: LiveUpdateContext(deltaTime: 0.7))
        XCTAssertEqual(restored.value, parameter.value, accuracy: 1e-12)
    }

    func testBeatPeriodRoundTrips() throws {
        let lfo = try LiveLFO(period: .beats(2), phase: -0.25)
        XCTAssertEqual(try roundTrip(lfo), lfo)
    }

    func testManualLatchSurvives() throws {
        var parameter = try LiveParameterLFOSimple(value: 0.5, lfo: LiveLFO(period: .seconds(2)))
        parameter.setManualValue(0.8)
        let restored = try roundTrip(parameter)
        XCTAssertEqual(restored.mode, .manual)
        XCTAssertEqual(restored.value, 0.8)
        XCTAssertEqual(restored.manualValue, 0.8)
        XCTAssertNotNil(restored.lfo)
    }

    func testAReturnInProgressResumes() throws {
        var parameter = try LiveParameterLFOSimple(value: 0.5, lfo: LiveLFO(period: .seconds(2)), returnDuration: 1)
        parameter.setManualValue(1)
        parameter.releaseManualControl()
        parameter.update(context: LiveUpdateContext(deltaTime: 0.25))
        var restored = try roundTrip(parameter)
        XCTAssertEqual(restored.mode, .returning)

        parameter.update(context: LiveUpdateContext(deltaTime: 0.25))
        restored.update(context: LiveUpdateContext(deltaTime: 0.25))
        XCTAssertEqual(restored.value, parameter.value, accuracy: 1e-12)
    }

    func testAFileCannotBringBackWhatTheInitializerRefuses() {
        XCTAssertThrowsError(try decode(#"{"range":[0,1],"returnDuration":-1,"value":0.5,"manualValue":0.5,"mode":"manual"}"#)) {
            XCTAssertEqual($0 as? LiveParameterError, .invalidReturnDuration)
        }
        XCTAssertThrowsError(try decode(#"{"range":[1,1],"returnDuration":0.3,"value":0.5,"manualValue":0.5,"mode":"manual"}"#)) {
            XCTAssertEqual($0 as? LiveParameterError, .invalidRange)
        }
        XCTAssertThrowsError(try decode(#"{"range":[0,1],"returnDuration":0.3,"value":0.5,"manualValue":0.5,"mode":"automatic","lfo":{"period":{"unit":"seconds","length":0},"phase":0}}"#)) {
            XCTAssertEqual($0 as? LiveParameterError, .invalidPeriod)
        }
    }

    func testWithoutAnLFOTheModeIsAlwaysManualAndValuesStayInRange() throws {
        let parameter = try decode(#"{"range":[0,1],"returnDuration":0.3,"value":5,"manualValue":-3,"mode":"automatic"}"#)
        XCTAssertEqual(parameter.mode, .manual)
        XCTAssertEqual(parameter.value, 1)
        XCTAssertEqual(parameter.manualValue, 0)
    }
}
