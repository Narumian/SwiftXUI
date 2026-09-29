import Testing
@testable import SwiftXUI

private func render(_ view: some XView, canvas: Size = Size(width: 300, height: 200)) -> (RecordingCanvas, RenderResult) {
    let surface = RecordingCanvas()
    let result = LayoutHost(canvas: canvas).render(view, into: surface)
    return (surface, result)
}

@Test func positionCentresTheViewAtThePoint() {
    let (surface, _) = render(Color.black.frame(width: 40, height: 20).position(x: 150, y: 100))
    #expect(surface.fills[0].rect.isApproximately(Rect(x: 130, y: 90, width: 40, height: 20)))
}

@Test func positionedFrameFlowsToItsAnchor() {
    // .anchor sits on the content, inside .position, so it reports the placed rect
    let (_, result) = render(
        Color.clear.frame(width: 80, height: 60).anchor("box").position(x: 200, y: 120)
    )
    #expect(result.anchors["box"]?.isApproximately(Rect(x: 160, y: 90, width: 80, height: 60)) == true)
}

@Test func positionKeepsTheNaturalSizeForTheParentSlot() {
    // the stack still leaves a 40-wide slot; only where it draws changes
    let view = HStack(spacing: 0) {
        Color.black.frame(width: 40, height: 40).position(x: 999, y: 999)
        Color.white.frame(width: 40, height: 40)
    }
    let (surface, _) = render(view)
    #expect(surface.fills[1].rect.x == 40)   // sibling sits after the 40-wide slot
}
