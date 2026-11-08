import XCTest
import XLive
import XUI

private struct TestLive: XLive {
    var elapsed = 0.0
    var body: some XView { Text("Live") }
    mutating func update(context: LiveUpdateContext) async { elapsed += context.deltaTime }
}

final class XLiveProtocolTests: XCTestCase {
    func testValueCanUpdateThroughExistential() async throws {
        var live: any XLive = TestLive()
        await live.update(context: .init(deltaTime: 0.25))
        await live.update(context: .init(deltaTime: 0.5))
        let result = try XCTUnwrap(live as? TestLive)
        XCTAssertEqual(result.elapsed, 0.75)
    }
}
