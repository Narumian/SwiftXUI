import XCTest
import XLive

final class LiveAmountTests: XCTestCase {
    func testGainCurve() {
        XCTAssertEqual(LiveAmount.gain(0), 0)
        XCTAssertEqual(LiveAmount.gain(0.25), 0.5, accuracy: 1e-12)
        XCTAssertEqual(LiveAmount.gain(0.5), 1, accuracy: 1e-12)
        XCTAssertEqual(LiveAmount.gain(1), 100, accuracy: 1e-9)
        XCTAssertEqual(LiveAmount.gain(.nan), 1)
        XCTAssertEqual(LiveAmount.gain(-3), 0)
        XCTAssertEqual(LiveAmount.gain(7), 100, accuracy: 1e-9)
    }

    func testAmountIsTheInverseOfGain() {
        for amount in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(LiveAmount.amount(forGain: LiveAmount.gain(amount)), amount, accuracy: 1e-9)
        }
    }

    func testScaleKeepsTheCenterFixed() {
        XCTAssertEqual(LiveAmount.scale(0.5, around: 0.5, amount: 1), 0.5)
        XCTAssertEqual(LiveAmount.scale(0.75, around: 0.5, amount: 0.25), 0.625, accuracy: 1e-12)
        XCTAssertEqual(LiveAmount.scale(0, around: 0, amount: 1), 0)
        XCTAssertEqual(LiveAmount.scale(0.5, around: 0, amount: 0.5), 0.5, accuracy: 1e-12)
        XCTAssertGreaterThan(LiveAmount.scale(0.6, around: 0.5, amount: 1), 1, "not clamped")
    }

    func testResponseCurve() {
        for v in [0.0, 0.2, 0.5, 1] { XCTAssertEqual(LiveAmount.response(v, curve: 0.5), v, accuracy: 1e-12) }
        XCTAssertGreaterThan(LiveAmount.response(0.5, curve: 0.25), 0.5, "low curve lifts")
        XCTAssertLessThan(LiveAmount.response(0.5, curve: 0.75), 0.5, "high curve lowers")
        XCTAssertEqual(LiveAmount.response(0.5, curve: 0.25) + LiveAmount.response(0.5, curve: 0.75), 1, accuracy: 1e-12)
        XCTAssertEqual(LiveAmount.response(0.3, curve: 0), 1, "exponent 0")
        XCTAssertEqual(LiveAmount.response(0, curve: 0.9), 0)
        XCTAssertEqual(LiveAmount.response(1, curve: 0.9), 1)
        XCTAssertEqual(LiveAmount.response(.nan, curve: 0.5), 0)
    }
}
