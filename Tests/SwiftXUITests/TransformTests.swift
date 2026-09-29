import Testing
@testable import SwiftXUI

private let canvas = Size(width: 300, height: 200)

private func render(_ view: some XView) -> RecordingCanvas {
    let surface = RecordingCanvas()
    LayoutHost(canvas: canvas).render(view, into: surface)
    return surface
}

@Test func transformTranslatesTheDrawnPixelsNotTheLayout() {
    let plain = render(Color.black.frame(width: 40, height: 40, alignment: .topLeading))
    let moved = render(
        Color.black.frame(width: 40, height: 40, alignment: .topLeading)
            .transform(.translation(x: 100, y: 50))
    )
    // same layout slot (0,0), pixels shifted by the transform
    #expect(plain.fills[0].rect.isApproximately(Rect(x: 0, y: 0, width: 40, height: 40)))
    #expect(moved.fills[0].rect.isApproximately(Rect(x: 100, y: 50, width: 40, height: 40)))
}

@Test func transformScopeIsPoppedForSiblings() {
    let view = VStack(spacing: 0) {
        Color.black.frame(width: 40, height: 40).transform(.translation(x: 200, y: 0))
        Color.white.frame(width: 40, height: 40)
    }
    let f = render(view).fills
    // VStack is only 40 wide (its content), pinned top-leading → cells at x=0
    #expect(f[0].rect.x == 200)                // shifted by the transform
    #expect(f[1].rect.x == 0)                  // sibling unaffected — the scope was popped
}

@Test func identityTransformIsANoOp() {
    let a = render(Color.black.frame(width: 40, height: 40))
    let b = render(Color.black.frame(width: 40, height: 40).transform(.identity))
    #expect(a.fills[0].rect.isApproximately(b.fills[0].rect))
}

@Test func nestedTransformsCompose() {
    let view = Color.black.frame(width: 10, height: 10, alignment: .topLeading)
        .transform(.translation(x: 5, y: 0))
        .transform(.translation(x: 0, y: 7))
    #expect(render(view).fills[0].rect.origin == Point(x: 5, y: 7))
}

@Test func scaleEffectUsesTheViewCenterAsDefaultAnchor() {
    let view = Color.black
        .frame(width: 40, height: 20, alignment: .topLeading)
        .scaleEffect(x: 2, y: 2)
    #expect(render(view).fills[0].rect.isApproximately(Rect(x: -20, y: -10, width: 80, height: 40)))
}

@Test func anchoredScaleEffectUsesResolvedFrame() {
    let view = Color.black
        .frame(width: 40, height: 20, alignment: .topLeading)
        .scaleEffect(x: 2, y: 2, anchor: .bottomTrailing)
    #expect(render(view).fills[0].rect.isApproximately(Rect(x: -40, y: -20, width: 80, height: 40)))
}
