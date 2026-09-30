import Testing
@testable import XUI

private let canvas = Size(width: 1000, height: 800)

@XUIActor
private func render(_ view: some XView) async -> (RecordingCanvas, RenderResult) {
    let surface = RecordingCanvas()
    let result = await LayoutHost(canvas: canvas).render(view, into: surface)
    return (surface, result)
}

@Test @XUIActor func colorFillsTheCanvas() async {
    let (surface, _) = await render(Color.black)
    #expect(surface.fills.count == 1)
    #expect(surface.fills[0].rect.isApproximately(Rect(x: 0, y: 0, width: 1000, height: 800)))
}

@Test @XUIActor func fixedFramePinsTopLeadingAtRoot() async {
    let (surface, _) = await render(Color.white.frame(width: 120, height: 90))
    #expect(surface.fills[0].rect.isApproximately(Rect(x: 0, y: 0, width: 120, height: 90)))
}

@Test @XUIActor func frameCentersContentInsideItsBox() async {
    // Outer frame is 400x400 at the origin; inner fixed 100x100 sits centered.
    let view = Color.white
        .frame(width: 100, height: 100)
        .frame(width: 400, height: 400)
    let (surface, _) = await render(view)
    #expect(surface.fills[0].rect.isApproximately(Rect(x: 150, y: 150, width: 100, height: 100)))
}

@Test @XUIActor func frameAlignmentLeadingTop() async {
    let view = Color.white
        .frame(width: 100, height: 100)
        .frame(width: 400, height: 400, alignment: .topLeading)
    let (surface, _) = await render(view)
    #expect(surface.fills[0].rect.isApproximately(Rect(x: 0, y: 0, width: 100, height: 100)))
}

@Test @XUIActor func emptyViewPaintsNothing() async {
    let (surface, _) = await render(EmptyView())
    #expect(surface.fills.isEmpty)
}

@Test @XUIActor func builderConditionalLowersActiveBranchOnly() async {
    struct Probe: XView {
        var flag: Bool
        var body: some XView {
            if flag { Color.black } else { Color.white }
        }
    }
    let (surface, _) = await render(Probe(flag: true))
    #expect(surface.fills.count == 1)
    #expect(surface.fills[0].color == .black)
}

@Test @XUIActor func builderTupleKeepsEveryChild() async {
    struct Probe: XView {
        var body: some XView {
            Color.black
            Color.white
            Color.black
        }
    }
    let (surface, _) = await render(Probe())
    #expect(surface.fills.count == 3)
}

// MARK: fractional frame

@XUIActor
private func fractionFrames(_ view: some XView, canvas: Size = Size(width: 300, height: 200)) async -> [Rect] {
    let surface = RecordingCanvas()
    await LayoutHost(canvas: canvas).render(view, into: surface)
    return surface.fills.map(\.rect)
}

@Test @XUIActor func fractionFrameTakesShareOfOffer() async {
    let f = await fractionFrames(Color.white.frame(width: .fraction(0.5), height: .fraction(0.25)))
    #expect(f[0].isApproximately(Rect(x: 0, y: 0, width: 150, height: 50)))
}

@Test @XUIActor func fractionAndPointsMixAndLiteralsStayPoints() async {
    let f = await fractionFrames(Color.white.frame(width: 100, height: .fraction(.golden)))
    #expect(abs(f[0].width - 100) < 0.001)
    #expect(abs(f[0].height - 200 * 0.618_033_988_749_895) < 0.001)
}

@Test @XUIActor func fractionIsStableUnderWrappers() async {
    // Wrappers re-measure a placed child; the result must not shrink each time.
    let f = await fractionFrames(
        Color.white.frame(width: .fraction(0.5), height: .fraction(0.5))
            .onTapGesture(id: "a", label: "a") {}
            .control(XControl(id: "c", label: "c"))
            .padding(10))
    #expect(abs(f[0].width - 150) < 0.001 && abs(f[0].height - 100) < 0.001)
}
