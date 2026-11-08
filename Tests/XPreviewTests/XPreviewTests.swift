import Testing
import XRender
import XUI
@testable import XPreview

@Test @XUIActor func previewRendersAViewToAPNGWithCostStats() async throws {
    let result = try await XPreview(measuredFrames: 10, settleFrames: 2).render(.phonePortrait) {
        VStack(spacing: 8) {
            Text("Hello", size: 20, color: .white)
            Color.red.frame(width: 100, height: 40).onTapGesture(id: "box", label: "box") {}
        }
    }
    #expect(Array(result.png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
    #expect(result.stats.frames == 10)
    #expect(result.stats.commands >= 2)
    #expect(result.stats.measureCalls > 0)
    #expect(result.stats.tapRegions == 1)
}

@Test @XUIActor func aScriptCanTapBeforeTheShot() async throws {
    final class Hits: @unchecked Sendable { var n = 0 }
    let hits = Hits()
    _ = try await XPreview(measuredFrames: 0, settleFrames: 1).render(.square, script: { driver in
        let tapped = await driver.tap("box")
        #expect(tapped)
    }) {
        Color.red.frame(width: 100, height: 40).onTapGesture(id: "box", label: "box") { hits.n += 1 }
    }
    #expect(hits.n == 1)
}
