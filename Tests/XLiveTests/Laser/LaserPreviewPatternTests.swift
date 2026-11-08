import XCTest
@testable import XLive

final class LaserPreviewPatternTests: XCTestCase {
    func testGridAppliesMaskAndKeepsPacketEndsBlack() throws {
        var mask = LaserMask.make(.polygon)
        mask.points = [.init(0, 0), .init(0.5, 0), .init(0.5, 1), .init(0, 1)]
        mask.dimmer = 0.25
        let points = try LaserPreviewPattern.grid(masks: .init(masks: [mask]))
        XCTAssertFalse(points.isEmpty)
        XCTAssertTrue(points.contains { !$0.isBlanked && $0.xy.x < -0.2 && abs($0.rgb.x - 0.025) < 0.001 })
        XCTAssertTrue(points.contains { !$0.isBlanked && $0.xy.x > 0.2 && abs($0.rgb.x - 0.1) < 0.001 })
        for index in stride(from: LaserPreviewPattern.packetLength - 1, to: points.count, by: LaserPreviewPattern.packetLength) {
            XCTAssertTrue(points[index].isBlanked && points[index].rgb == .zero)
        }
        XCTAssertEqual(points.last?.isBlanked, true)
    }

    func testOutlinesAreDrawnAtFullPowerEvenWhenTheMaskBlacksOut() throws {
        var polygon = LaserMask.make(.polygon)
        polygon.points = [.init(0.25, 0.25), .init(0.75, 0.25), .init(0.75, 0.75), .init(0.25, 0.75)]
        polygon.dimmer = 0 // blackout: the grid inside is dark, the outline must still show
        let points = try LaserPreviewPattern.grid(masks: .init(masks: [polygon]))
        func lit(_ test: (LaserPoint) -> Bool) -> Bool {
            points.contains { !$0.isBlanked && abs($0.rgb.x - LaserPreviewPattern.intensity) < 0.001 && test($0) }
        }
        // Left edge x = -0.5, sampled between the grid lines at y = 0.16 and 0.48.
        XCTAssertTrue(lit { abs($0.xy.x + 0.5) < 0.005 && abs($0.xy.y - 0.3) < 0.02 })
        // Top edge y = 0.5 and right edge x = 0.5.
        XCTAssertTrue(lit { abs($0.xy.y - 0.5) < 0.005 && abs($0.xy.x - 0.3) < 0.02 })
        XCTAssertTrue(lit { abs($0.xy.x - 0.5) < 0.005 && abs($0.xy.y + 0.3) < 0.02 })
        // The inside of the blackout mask carries no grid light; only the outline shows.
        XCTAssertFalse(points.contains { !$0.isBlanked && abs($0.xy.x) < 0.45 && abs($0.xy.y) < 0.45 })
        for index in stride(from: LaserPreviewPattern.packetLength - 1, to: points.count, by: LaserPreviewPattern.packetLength) {
            XCTAssertTrue(points[index].isBlanked && points[index].rgb == .zero)
        }
        XCTAssertEqual(points.count % LaserPreviewPattern.packetLength, 0)
    }

    func testEllipseOutlineIsDrawnAndDisabledOrMalformedMasksAreSkipped() throws {
        let ellipse = LaserMask.make(.ellipse) // (0.25,0.3)-(0.75,0.7)
        let outlined = try LaserPreviewPattern.grid(masks: .init(masks: [ellipse]))
        let plain = try LaserPreviewPattern.grid(masks: .init())
        XCTAssertGreaterThan(outlined.count, plain.count)
        // Rightmost point of the ellipse: x = 0.75 -> 0.5, y = 0.5 -> 0.
        XCTAssertTrue(outlined.contains { !$0.isBlanked && abs($0.xy.x - 0.5) < 0.01 && abs($0.xy.y) < 0.03 && abs($0.rgb.x - 0.1) < 0.001 })
        var disabled = ellipse; disabled.enabled = false
        var malformed = LaserMask.make(.polygon); malformed.points = [.init(0.1, 0.1), .init(0.2, 0.2)]
        XCTAssertNil(LaserPreviewPattern.outline(of: disabled))
        XCTAssertNil(LaserPreviewPattern.outline(of: malformed))
        XCTAssertEqual(try LaserPreviewPattern.grid(masks: .init(masks: [disabled, malformed])).count, plain.count)
    }
}
