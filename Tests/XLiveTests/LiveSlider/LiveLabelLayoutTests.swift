import XCTest
@testable import XLive
import XUI

final class LiveLabelLayoutTests: XCTestCase {
    /// Every character is 6 wide and 12 tall, whatever the font.
    private let measure: (String, Double, TextFont) -> Size = { text, _, _ in Size(width: Double(text.count) * 6, height: 12) }
    private let box = Rect(x: 10, y: 20, width: 62, height: 36)

    func testTheTwoLinesShareOneColumnInsetByThePadding() {
        let layout = LiveLabelLayout(title: "Gain", value: "0.50", in: box, measure: measure)
        XCTAssertEqual(layout.lines.map(\.text), ["Gain", "0.50"])
        XCTAssertEqual(layout.lines.map(\.isTitle), [true, false])
        for line in layout.lines {
            XCTAssertEqual(line.rect.x, 10 + LiveLabelLayout.horizontalPadding)
            XCTAssertEqual(line.rect.width, 62 - 2 * LiveLabelLayout.horizontalPadding)
        }
    }

    func testTheBlockIsCentredVerticallyWithAGapBetweenTheLines() {
        let layout = LiveLabelLayout(title: "Gain", value: "0.50", in: box, measure: measure)
        let height = 12 + LiveLabelLayout.lineGap + 12
        XCTAssertEqual(layout.lines[0].rect.y, box.midY - height / 2, accuracy: 1e-9)
        XCTAssertEqual(layout.lines[1].rect.y, layout.lines[0].rect.y + 12 + LiveLabelLayout.lineGap, accuracy: 1e-9)
        XCTAssertEqual(layout.lines[1].rect.maxY - box.midY, box.midY - layout.lines[0].rect.y, accuracy: 1e-9, "same room above and below")
    }

    func testANameTooWideForTheColumnIsCutToOneLine() {
        let layout = LiveLabelLayout(title: "Rotation speed", value: "0.5", in: box, measure: measure)
        XCTAssertEqual(layout.lines.filter(\.isTitle).count, 1)
        XCTAssertLessThan(layout.lines[0].text.count, "Rotation speed".count)
    }

    func testAValueTooWideWrapsOntoMoreLines() {
        let layout = LiveLabelLayout(title: "A", value: "12 34 56 78 90", in: box, measure: measure)
        XCTAssertGreaterThan(layout.lines.filter { !$0.isTitle }.count, 1)
    }

    func testAnEmptyValueLeavesOnlyTheNameCentredWithoutAGap() {
        let layout = LiveLabelLayout(title: "empty", value: "", in: box, measure: measure)
        XCTAssertEqual(layout.lines.count, 1)
        XCTAssertEqual(layout.lines[0].rect.midY, box.midY, accuracy: 1e-9)
    }

    func testABoxNarrowerThanItsPaddingHasNoRoomForText() {
        let layout = LiveLabelLayout(title: "Gain", value: "0.5", in: Rect(x: 0, y: 0, width: 10, height: 30), measure: measure)
        XCTAssertTrue(layout.lines.allSatisfy { $0.rect.width == 0 })
    }

    func testAFontThatMeasuresTallDoesNotPushTheLinesOutOfTheBox() {
        let tall: (String, Double, TextFont) -> Size = { text, size, _ in Size(width: Double(text.count) * 6, height: size * 2.07) }
        let layout = LiveLabelLayout(title: "Gain", value: "0.50", in: box, measure: tall)
        XCTAssertEqual(layout.lines[0].rect.height, LiveLabelLayout.maxLineHeight)
        XCTAssertGreaterThanOrEqual(layout.lines[0].rect.y, box.y)
        XCTAssertLessThanOrEqual(layout.lines[1].rect.maxY, box.maxY)
        XCTAssertEqual(layout.lines[1].rect.maxY - box.midY, box.midY - layout.lines[0].rect.y, accuracy: 1e-9)
    }
}
