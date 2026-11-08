import XCTest
import XLive

final class LiveValueMappingTests: XCTestCase {
    func testNormalizeAndValueRoundTrip() throws {
        let m = try LiveValueMapping(range: -10...30)
        XCTAssertEqual(m.normalized(10), 0.5)
        XCTAssertEqual(m.value(forNormal: 0.25), 0)
        XCTAssertEqual(m.value(forNormal: -2), -10)
        XCTAssertEqual(m.value(forNormal: 9), 30)
        XCTAssertNil(m.value(forNormal: .nan))
        XCTAssertNil(m.constrained(.infinity))
        XCTAssertEqual(m.normalized(50), 1.5, "not clamped")
    }

    func testStepSnapsFromTheLowerBound() throws {
        let m = try LiveValueMapping(range: 1...10, step: 2)
        XCTAssertEqual(m.value(forNormal: 0), 1)
        XCTAssertEqual(m.value(forNormal: 0.3), 3)   // 1 + 2.7 -> 1 + 1*2
        XCTAssertEqual(m.constrained(4.1), 5)
        XCTAssertEqual(m.value(forNormal: 1), 10, "10 snaps up to 11, which the range clamps back to 10")
        XCTAssertEqual(m.value(forNormal: 0.9), 9)
    }

    func testLimitNarrowsTheReachableRange() throws {
        let m = try LiveValueMapping(range: 0...100, limit: 20...80)
        XCTAssertEqual(m.reachable, 20...80)
        XCTAssertEqual(m.value(forNormal: 0), 20)
        XCTAssertEqual(m.value(forNormal: 1), 80)
        XCTAssertEqual(m.value(forNormal: 0.5), 50)
        let wide = try LiveValueMapping(range: 0...1, limit: -5...5)
        XCTAssertEqual(wide.reachable, 0...1)
    }

    func testValidationAndCodable() throws {
        XCTAssertThrowsError(try LiveValueMapping(range: 1...1))
        XCTAssertThrowsError(try LiveValueMapping(range: 0...1, limit: 2...3))
        XCTAssertThrowsError(try LiveValueMapping(range: 0...1, step: 0))
        XCTAssertThrowsError(try LiveValueMapping(range: 0...1, step: .nan))
        XCTAssertThrowsError(try LiveValueMapping(range: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude), "span overflows")
        XCTAssertThrowsError(try LiveValueMapping(range: 0...Double.infinity))
        let m = try LiveValueMapping(range: -1...1, limit: -0.5...0.5, step: 0.25)
        XCTAssertEqual(try JSONDecoder().decode(LiveValueMapping.self, from: JSONEncoder().encode(m)), m)
        XCTAssertThrowsError(try JSONDecoder().decode(LiveValueMapping.self, from: Data(#"{"range":[1,0]}"#.utf8)))
    }
}
