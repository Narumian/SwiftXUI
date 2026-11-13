import XCTest
@testable import XLive

final class LaserTestPatternsTests: XCTestCase {
    func testTheBundledILDATestPatternsLoad() throws {
        for (name, count) in [("ILDA 30K", 1415), ("ILDA 12K", 1191)] {
            let points = try LaserTestPatterns.points(named: name, intensity: 0.1)
            XCTAssertEqual(points.count, count, name)
            XCTAssertTrue(points.contains { !$0.isBlanked }, name)
            XCTAssertTrue(points.contains { $0.isBlanked }, name)
            XCTAssertLessThanOrEqual(points.map { $0.rgb.max() }.max() ?? 0, 0.1 + 1e-6, name)
        }
        XCTAssertThrowsError(try LaserTestPatterns.points(named: "nope", intensity: 0.1))
    }
}
