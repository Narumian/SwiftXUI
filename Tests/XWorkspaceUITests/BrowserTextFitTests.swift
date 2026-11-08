import Testing
import XUI
@testable import XWorkspaceUI

private let measure: @Sendable (String, Double, TextFont) -> Size = { string, size, _ in Size(width: Double(string.count) * size * 0.5, height: size * 1.2) }

@Test func shortNamesAreLeftAlone() {
    #expect(BrowserTextFit.compute("logo.png", size: 10, maxWidth: 100, middle: true, measure: measure) == "logo.png")
}

@Test func longFileNamesKeepTheirNumberAndExtension() {
    let fitted = BrowserTextFit.compute("alpha mask 123.jpg", size: 10, maxWidth: 60, middle: true, measure: measure)
    #expect(fitted.hasSuffix("123.jpg"))
    #expect(fitted.contains("…"))
    #expect(Double(fitted.count) * 5 <= 60)
}

@Test func foldersAndNamesWithoutExtensionsCutTheEnd() {
    let folder = BrowserTextFit.compute("Laser Shows Archive", size: 10, maxWidth: 50, middle: false, measure: measure)
    #expect(folder.hasSuffix("…") && Double(folder.count) * 5 <= 50)
    let bare = BrowserTextFit.compute("README_long_name", size: 10, maxWidth: 50, middle: true, measure: measure)
    #expect(bare.hasSuffix("…"))
}

@Test func aCellTooNarrowForTheExtensionFallsBackToAnEllipsis() {
    let fitted = BrowserTextFit.compute("a very long name.json", size: 10, maxWidth: 20, middle: true, measure: measure)
    #expect(Double(fitted.count) * 5 <= 20)
}

private final class CountingCanvas: XCanvas {
    private(set) var measures = 0
    func fillRect(_ rect: Rect, color: XColorValue) {}
    func drawText(_ string: String, in rect: Rect, fontSize: Double, font: TextFont, color: XColorValue,
                  alignment: HorizontalAlignment, outline: TextOutline?) {}
    func measureText(_ string: String, fontSize: Double, font: TextFont) -> Size {
        measures += 1
        return Size(width: Double(string.count) * fontSize * 0.5, height: fontSize * 1.2)
    }
}

@Test @XUIActor func aSteadyFrameMeasuresOnlyTheProbeForNames() async {
    let fit = BrowserTextFit()
    let names = (0..<40).map { "alpha mask \($0).jpg" }
    func frame() async -> Int {
        let canvas = CountingCanvas()
        let view = DrawLayer { rect, context in
            for name in names { _ = fit.fit(name, size: 11, maxWidth: 60, middle: true, context: context) }
        }
        _ = await LayoutHost(canvas: Size(width: 100, height: 100)).render(view, into: canvas, store: StateStore())
        return canvas.measures
    }
    let cold = await frame()
    let warm = await frame()
    #expect(cold > 40 * 2)
    #expect(warm <= 1)
}
