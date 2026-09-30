import Testing
@testable import XUI

@XUIActor
private func frames(_ view: some XView, canvas: Size = Size(width: 300, height: 200)) async -> [Rect] {
    let surface = RecordingCanvas()
    await LayoutHost(canvas: canvas).render(view, into: surface)
    return surface.fills.map(\.rect)
}

// MARK: HStack distribution

@Test @XUIActor func hstackSplitsFlexibleChildrenEvenly() async {
    // Two infinitely-flexible colors in a 300-wide canvas → 150 each.
    let f = await frames(HStack { Color.black; Color.white })
    #expect(f[0].isApproximately(Rect(x: 0, y: 0, width: 150, height: 200)))
    #expect(f[1].isApproximately(Rect(x: 150, y: 0, width: 150, height: 200)))
}

@Test @XUIActor func hstackSpacingIsSubtractedBeforeSplit() async {
    let f = await frames(HStack(spacing: 20) { Color.black; Color.white })
    #expect(f[0].isApproximately(Rect(x: 0, y: 0, width: 140, height: 200)))
    #expect(f[1].isApproximately(Rect(x: 160, y: 0, width: 140, height: 200)))
}

@Test @XUIActor func hstackFixedChildKeepsSizeFlexibleTakesRest() async {
    let view = HStack {
        Color.black.frame(width: 40)
        Color.white
    }
    let f = await frames(view)
    #expect(f[0].isApproximately(Rect(x: 0, y: 0, width: 40, height: 200)))
    #expect(f[1].isApproximately(Rect(x: 40, y: 0, width: 260, height: 200)))
}

@Test @XUIActor func hstackSpacerPushesContentToEdges() async {
    // A bare HStack is only as tall as its tallest child (40 here), pinned
    // top-leading by the root — so the far cell lands at y == 0, x == 260.
    let view = HStack {
        Color.black.frame(width: 40, height: 40)
        Spacer()
        Color.white.frame(width: 40, height: 40)
    }
    let f = await frames(view)
    #expect(f[0].x == 0)
    #expect(f[1].isApproximately(Rect(x: 260, y: 0, width: 40, height: 40)))
}

@Test @XUIActor func hstackCrossAlignmentTop() async {
    let view = HStack(alignment: .top) {
        Color.black.frame(width: 40, height: 40)
        Color.white.frame(width: 40, height: 120)
    }
    let f = await frames(view)
    #expect(f[0].y == 0)
    #expect(f[1].y == 0)
}

@Test @XUIActor func hstackCrossAlignmentDefaultsToCenter() async {
    // Stack is 80x120 (its own content), so the short cell centers within 120.
    let view = HStack {
        Color.black.frame(width: 40, height: 40)
        Color.white.frame(width: 40, height: 120)
    }
    let f = await frames(view)
    #expect(f[0].isApproximately(Rect(x: 0, y: 40, width: 40, height: 40)))
}

// MARK: VStack

@Test @XUIActor func vstackStacksTopToBottom() async {
    let view = VStack(spacing: 10) {
        Color.black.frame(height: 30)
        Color.white.frame(height: 50)
    }
    let f = await frames(view)
    #expect(f[0].isApproximately(Rect(x: 0, y: 0, width: 300, height: 30)))
    #expect(f[1].isApproximately(Rect(x: 0, y: 40, width: 300, height: 50)))
}

// MARK: ZStack

@Test @XUIActor func zstackOverlaysAndAligns() async {
    let view = ZStack(alignment: .bottomTrailing) {
        Color.black
        Color.white.frame(width: 50, height: 50)
    }
    let f = await frames(view)
    #expect(f[0].isApproximately(Rect(x: 0, y: 0, width: 300, height: 200)))
    #expect(f[1].isApproximately(Rect(x: 250, y: 150, width: 50, height: 50)))
}

// MARK: modifiers

@Test @XUIActor func frameMaxWidthInfinityFills() async {
    let f = await frames(Color.black.frame(maxWidth: .infinity, maxHeight: .infinity))
    #expect(f[0].isApproximately(Rect(x: 0, y: 0, width: 300, height: 200)))
}

@Test @XUIActor func frameMaxWidthFiniteCapsGrowth() async {
    // In an HStack the capped frame grows only to 100; the color takes the rest.
    let view = HStack {
        Color.black.frame(maxWidth: 100)
        Color.white
    }
    let f = await frames(view)
    #expect(f[0].width == 100)
    #expect(f[1].isApproximately(Rect(x: 100, y: 0, width: 200, height: 200)))
}

@Test @XUIActor func paddingInsetsContent() async {
    let f = await frames(Color.black.padding(20))
    #expect(f[0].isApproximately(Rect(x: 20, y: 20, width: 260, height: 160)))
}

@Test @XUIActor func paddingEdgesOnlyChosenSides() async {
    let f = await frames(Color.black.padding(.horizontal, 25))
    #expect(f[0].isApproximately(Rect(x: 25, y: 0, width: 250, height: 200)))
}

@Test @XUIActor func offsetShiftsWithoutResizing() async {
    let view = VStack {
        Color.black.frame(width: 40, height: 40).offset(x: 10, y: 5)
        Color.white.frame(width: 40, height: 40)
    }
    let f = await frames(view)
    // VStack is 40 wide (its content); root pins it top-leading, so cells sit
    // at x == 0. First cell is then shifted by (10, 5).
    #expect(f[0].isApproximately(Rect(x: 10, y: 5, width: 40, height: 40)))
    // Second cell unaffected by the first's offset.
    #expect(f[1].isApproximately(Rect(x: 0, y: 40, width: 40, height: 40)))
}

@Test @XUIActor func nestedStacksResolve() async {
    let view = VStack(spacing: 0) {
        HStack(spacing: 0) {
            Color.black.frame(width: 100)
            Color.white
        }
        .frame(height: 60)
        Color.black.frame(height: 40)
    }
    let f = await frames(view)
    #expect(f[0].isApproximately(Rect(x: 0, y: 0, width: 100, height: 60)))
    #expect(f[1].isApproximately(Rect(x: 100, y: 0, width: 200, height: 60)))
    #expect(f[2].isApproximately(Rect(x: 0, y: 60, width: 300, height: 40)))
}
