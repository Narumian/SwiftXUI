import Testing
@testable import XUI

private let canvas = Size(width: 1000, height: 800)

private func render(_ view: some XView) -> (RecordingCanvas, RenderResult) {
    let surface = RecordingCanvas()
    let result = LayoutHost(canvas: canvas).render(view, into: surface)
    return (surface, result)
}

@Test func colorFillsTheCanvas() {
    let (surface, _) = render(Color.black)
    #expect(surface.fills.count == 1)
    #expect(surface.fills[0].rect.isApproximately(Rect(x: 0, y: 0, width: 1000, height: 800)))
}

@Test func fixedFramePinsTopLeadingAtRoot() {
    let (surface, _) = render(Color.white.frame(width: 120, height: 90))
    #expect(surface.fills[0].rect.isApproximately(Rect(x: 0, y: 0, width: 120, height: 90)))
}

@Test func frameCentersContentInsideItsBox() {
    // Outer frame is 400x400 at the origin; inner fixed 100x100 sits centered.
    let view = Color.white
        .frame(width: 100, height: 100)
        .frame(width: 400, height: 400)
    let (surface, _) = render(view)
    #expect(surface.fills[0].rect.isApproximately(Rect(x: 150, y: 150, width: 100, height: 100)))
}

@Test func frameAlignmentLeadingTop() {
    let view = Color.white
        .frame(width: 100, height: 100)
        .frame(width: 400, height: 400, alignment: .topLeading)
    let (surface, _) = render(view)
    #expect(surface.fills[0].rect.isApproximately(Rect(x: 0, y: 0, width: 100, height: 100)))
}

@Test func emptyViewPaintsNothing() {
    let (surface, _) = render(EmptyView())
    #expect(surface.fills.isEmpty)
}

@Test func builderConditionalLowersActiveBranchOnly() {
    struct Probe: XView {
        var flag: Bool
        var body: some XView {
            if flag { Color.black } else { Color.white }
        }
    }
    let (surface, _) = render(Probe(flag: true))
    #expect(surface.fills.count == 1)
    #expect(surface.fills[0].color == .black)
}

@Test func builderTupleKeepsEveryChild() {
    struct Probe: XView {
        var body: some XView {
            Color.black
            Color.white
            Color.black
        }
    }
    let (surface, _) = render(Probe())
    #expect(surface.fills.count == 3)
}

// MARK: fractional frame

private func fractionFrames(_ view: some XView, canvas: Size = Size(width: 300, height: 200)) -> [Rect] {
    let surface = RecordingCanvas()
    LayoutHost(canvas: canvas).render(view, into: surface)
    return surface.fills.map(\.rect)
}

@Test func fractionFrameTakesShareOfOffer() {
    let f = fractionFrames(Color.white.frame(width: .fraction(0.5), height: .fraction(0.25)))
    #expect(f[0].isApproximately(Rect(x: 0, y: 0, width: 150, height: 50)))
}

@Test func fractionAndPointsMixAndLiteralsStayPoints() {
    let f = fractionFrames(Color.white.frame(width: 100, height: .fraction(.golden)))
    #expect(abs(f[0].width - 100) < 0.001)
    #expect(abs(f[0].height - 200 * 0.618_033_988_749_895) < 0.001)
}

@Test func fractionIsStableUnderWrappers() {
    // Wrappers re-measure a placed child; the result must not shrink each time.
    let f = fractionFrames(
        Color.white.frame(width: .fraction(0.5), height: .fraction(0.5))
            .onTapGesture(id: "a", label: "a") {}
            .control(XControl(id: "c", label: "c"))
            .padding(10))
    #expect(abs(f[0].width - 150) < 0.001 && abs(f[0].height - 100) < 0.001)
}
