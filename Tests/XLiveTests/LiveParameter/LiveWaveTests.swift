import XCTest
import XLive

final class LiveWaveTests: XCTestCase {
    func testPeriodicShapes() {
        XCTAssertEqual(LiveWave(shape: .sin).sample(cycles: 0), 0.5, accuracy: 1e-12)
        XCTAssertEqual(LiveWave(shape: .sin).sample(cycles: 0.25), 1, accuracy: 1e-12)
        XCTAssertEqual(LiveWave(shape: .cos).sample(cycles: 0), 1, accuracy: 1e-12)
        let tri = LiveWave(shape: .tri)
        XCTAssertEqual(tri.sample(cycles: 0), 0)
        XCTAssertEqual(tri.sample(cycles: 0.25), 0.5, accuracy: 1e-12)
        XCTAssertEqual(tri.sample(cycles: 0.5), 1, accuracy: 1e-12)
        XCTAssertEqual(tri.sample(cycles: 0.75), 0.5, accuracy: 1e-12)
        XCTAssertEqual(LiveWave(shape: .saw).sample(cycles: 0.3), 0.3, accuracy: 1e-12)
        XCTAssertEqual(LiveWave(shape: .square).sample(cycles: 0.49), 0)
        XCTAssertEqual(LiveWave(shape: .square).sample(cycles: 0.5), 1)
        let pwm = LiveWave(shape: .pwm, pulseWidth: 0.25)
        XCTAssertEqual(pwm.sample(cycles: 0.2), 1)
        XCTAssertEqual(pwm.sample(cycles: 0.3), 0)
    }

    func testNegativePositionsWrapLikePositiveOnes() {
        let saw = LiveWave(shape: .saw)
        XCTAssertEqual(saw.sample(cycles: -0.25), 0.75, accuracy: 1e-12)
        XCTAssertEqual(saw.sample(cycles: -3.25), 0.75, accuracy: 1e-12)
        for shape in LiveWaveShape.allCases {
            let wave = LiveWave(shape: shape, seed: 7)
            for cycles in [-1e18, -12.3, -0.0001, 0, 0.5, 99.9, 1e18] {
                let v = wave.sample(cycles: cycles)
                XCTAssertTrue((0...1).contains(v), "\(shape) \(cycles) -> \(v)")
            }
            XCTAssertEqual(wave.sample(cycles: .nan), 0.5)
            XCTAssertEqual(wave.sample(cycles: .infinity), 0.5)
        }
    }

    func testNoiseIsSeededAndContinuous() {
        let a = LiveWave(shape: .noise, seed: 1), b = LiveWave(shape: .noise, seed: 2)
        XCTAssertEqual(a.sample(cycles: 3.4), LiveWave(shape: .noise, seed: 1).sample(cycles: 3.4))
        XCTAssertNotEqual(a.sample(cycles: 3.4), b.sample(cycles: 3.4))
        // Continuous across a lattice point, and exact on it.
        let left = a.sample(cycles: 5 - 1e-9), right = a.sample(cycles: 5 + 1e-9)
        XCTAssertEqual(left, right, accuracy: 1e-6)
    }

    func testNoiseIsContinuousAcrossTrackedCycleBoundary() {
        let wave = LiveWave(shape: .noise, seed: 5)
        var phase = LivePhase()
        phase.advance(seconds: 0.999_999, cyclesPerSecond: 1)
        let left = wave.sample(position: phase.position())
        phase.advance(seconds: 0.000_002, cyclesPerSecond: 1)
        let right = wave.sample(position: phase.position())
        XCTAssertEqual(phase.cycleIndex, 1)
        XCTAssertEqual(left, right, accuracy: 1e-5)
    }

    func testRandomHoldsForTheWholeCycle() {
        let w = LiveWave(shape: .random, seed: 9)
        XCTAssertEqual(w.sample(cycles: 4.0), w.sample(cycles: 4.99))
        XCTAssertNotEqual(w.sample(cycles: 4.5), w.sample(cycles: 5.5))
    }

    func testRandomUsesTheTrackedCycleIndex() {
        let wave = LiveWave(shape: .random, seed: 9)
        var phase = LivePhase()
        phase.advance(seconds: 0.75, cyclesPerSecond: 1)
        let first = wave.sample(position: phase.position())
        phase.advance(seconds: 0.5, cyclesPerSecond: 1)
        let next = wave.sample(position: phase.position())
        XCTAssertNotEqual(first, next)
    }

    func testCodableRoundTripAndPulseWidthClamp() throws {
        let wave = LiveWave(shape: .pwm, pulseWidth: 4, seed: 42)
        XCTAssertEqual(wave.pulseWidth, 1)
        let decoded = try JSONDecoder().decode(LiveWave.self, from: JSONEncoder().encode(wave))
        XCTAssertEqual(decoded, wave)
        let sparse = try JSONDecoder().decode(LiveWave.self, from: Data(#"{"shape":"pwm"}"#.utf8))
        XCTAssertEqual(sparse, LiveWave(shape: .pwm))
    }
}
