import Testing
import XUI
@testable import XWorkspaceUI

private let policy = BrowserLayoutPolicy()

@Test
func narrowTallBoxesUseRows() {
    let layout = policy.layout(for: Size(width: 240, height: 640))
    #expect(layout.shape == .tall)
    #expect(layout.usesRows && layout.tracks == 1 && layout.axis == .vertical)
    #expect(layout.chrome == .top)
}

@Test
func widerTallBoxesUseTiles() {
    let layout = policy.layout(for: Size(width: 360, height: 800))
    #expect(layout.shape == .tall)
    #expect(!layout.usesRows)
    #expect(layout.tracks == 3)
}

@Test
func shortWideBoxesBecomeAScrollingStrip() {
    let layout = policy.layout(for: Size(width: 900, height: 140))
    #expect(layout.shape == .wide)
    #expect(layout.axis == .horizontal && layout.tracks == 1)
    #expect(layout.chrome == .leading)
    #expect(policy.layout(for: Size(width: 900, height: 230)).tracks == 2)
}

@Test
func roomyBoxesGetAFolderColumn() {
    #expect(policy.layout(for: Size(width: 1100, height: 700)).chrome == .sidebar)
    #expect(policy.layout(for: Size(width: 800, height: 760)).chrome == .sidebar)
    #expect(policy.layout(for: Size(width: 600, height: 560)).chrome == .top)
}

@Test
func squareBoxesFitTilesToTheirWidth() {
    let layout = policy.layout(for: Size(width: 520, height: 480))
    #expect(layout.shape == .square)
    #expect(layout.tracks == 4)
    #expect(layout.itemLength == .aspect(1))
}

@Test
func shapeDoesNotFlickerAcrossTheBoundary() {
    // 0.85 is between enter (0.8) and exit (0.92): the previous shape wins.
    let size = Size(width: 850, height: 1000)
    #expect(policy.shape(for: size, previous: .tall) == .tall)
    #expect(policy.shape(for: size, previous: .square) == .square)
    #expect(policy.shape(for: size, previous: nil) == .square)
    #expect(policy.shape(for: Size(width: 1200, height: 1000), previous: .wide) == .wide)
    #expect(policy.shape(for: Size(width: 1200, height: 1000), previous: .square) == .square)
}

@Test
func degenerateBoxesDoNotCrash() {
    _ = policy.layout(for: .zero)
    _ = policy.layout(for: Size(width: 10, height: 10))
    #expect(policy.layout(for: Size(width: 10, height: 10)).tracks >= 1)
}
