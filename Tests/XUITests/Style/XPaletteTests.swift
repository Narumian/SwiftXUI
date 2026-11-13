import XCTest
@testable import XUI

final class XPaletteTests: XCTestCase {
    private func palettes() -> [(String, XPalette)] {
        var all: [(String, XPalette)] = []
        for p in XAccentChoice.all { for s in XAccentChoice.all { all.append(("\(p.name)/\(s.name)", XPalette(primary: p, secondary: s))) } }
        return all
    }

    func testTheContrastOfEveryRoleHoldsForEveryChoice() {
        for (name, palette) in palettes() {
            let n = palette.neutral
            for (label, accent) in [("primary", palette.primary), ("secondary", palette.secondary), ("success", palette.success), ("danger", palette.danger)] {
                for surface in [n.panel, n.raised, n.inset] {
                    XCTAssertGreaterThanOrEqual(accent.text.contrast(with: surface), 7, "\(name) \(label) text")
                    XCTAssertGreaterThanOrEqual(accent.base.contrast(with: surface), 4.5, "\(name) \(label) base")
                    XCTAssertGreaterThanOrEqual(accent.border.contrast(with: surface), 3, "\(name) \(label) border")
                }
                XCTAssertGreaterThanOrEqual(XColorValue.white.contrast(with: accent.fill), 4.5, "\(name) \(label) white on fill")
                XCTAssertGreaterThanOrEqual(accent.text.contrast(with: accent.subtle), 7, "\(name) \(label) text on subtle")
            }
        }
    }

    func testNeutralTextReadsOnEverySurface() {
        let n = XPalette.standard.neutral
        for surface in [n.panel, n.raised, n.raisedHigh, n.window, n.inset] {
            XCTAssertGreaterThanOrEqual(n.textPrimary.contrast(with: surface), 10)
            XCTAssertGreaterThanOrEqual(n.textSecondary.contrast(with: surface), 4.5)
            XCTAssertGreaterThanOrEqual(n.textDisabled.contrast(with: surface), 3)
        }
        XCTAssertGreaterThanOrEqual(n.borderStrong.contrast(with: n.panel), 2)
    }

    func testNeutralsAreGreyAndGetLighterStepByStep() {
        let n = XPalette.standard.neutral
        let steps = [n.inset, n.window, n.panel, n.raised, n.raisedHigh, n.border, n.borderStrong, n.textDisabled, n.textSecondary, n.textPrimary]
        for c in steps {
            XCTAssertEqual(c.red, c.green, accuracy: 1e-3)
            XCTAssertEqual(c.green, c.blue, accuracy: 1e-3)
        }
        for (a, b) in zip(steps, steps.dropFirst()) { XCTAssertLessThan(a.relativeLuminance, b.relativeLuminance) }
    }

    func testAccentStepsGetLighterAndKeepTheirHue() {
        for choice in XAccentChoice.all {
            let a = XAccent(hue: choice.hue)
            let steps = [a.subtle, a.fill, a.border, a.base, a.text]
            for (x, y) in zip(steps, steps.dropFirst()) { XCTAssertLessThan(x.relativeLuminance, y.relativeLuminance, choice.name) }
            for c in steps { XCTAssertTrue((0...1).contains(c.red) && (0...1).contains(c.green) && (0...1).contains(c.blue)) }
        }
    }

    func testTheChoicesStayClearOfTheStateHues() {
        func distance(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }
        for choice in XAccentChoice.all {
            XCTAssertGreaterThanOrEqual(distance(choice.hue, XPalette.dangerHue), 25, choice.name)
            XCTAssertGreaterThanOrEqual(distance(choice.hue, XPalette.successHue), 55, choice.name)
        }
    }

    func testTheDefaultsAreBlueAndAmber() {
        XCTAssertEqual(XPalette.standard.primary.hue, XAccentChoice.blue.hue)
        XCTAssertEqual(XPalette.standard.secondary.hue, XAccentChoice.amber.hue)
        XCTAssertEqual(XAccentChoice.named("Violet"), .violet)
        XCTAssertNil(XAccentChoice.named("Red"))
    }

    func testContrastMatchesTheWCAGExtremes() {
        XCTAssertEqual(XColorValue.white.contrast(with: .black), 21, accuracy: 1e-9)
        XCTAssertEqual(XColorValue.white.contrast(with: .white), 1, accuracy: 1e-9)
    }

    func testControlsTakeTheirColoursFromThePaletteUnlessTold() {
        let palette = XPalette(primary: .violet, secondary: .orange)
        let field = TextFieldStyle().colors(palette)
        XCTAssertEqual(field.caret, palette.primary.base)
        XCTAssertEqual(field.focusedBorder, palette.primary.base)
        XCTAssertEqual(field.background, palette.neutral.inset)
        var custom = TextFieldStyle()
        custom.caret = XColorValue(1, 0, 0)
        XCTAssertEqual(custom.colors(palette).caret, XColorValue(1, 0, 0))
        XCTAssertEqual(custom.colors(palette).focusedBorder, palette.primary.base)
        let keys = KeyboardStyle().colors(palette)
        XCTAssertEqual(keys.accentKey, palette.primary.fill)
        XCTAssertEqual(keys.key, palette.neutral.raised)
    }

    func testTheEnvironmentPaletteDefaultsToTheStandardOne() {
        var environment = EnvironmentValues()
        XCTAssertEqual(environment.palette, XPalette.standard)
        environment.palette = XPalette(primary: .cyan, secondary: .magenta)
        XCTAssertEqual(environment.palette.primary, XAccent.cached(hue: XAccentChoice.cyan.hue))
    }
}
