import Testing
@testable import XUI

private let canvas = Size(width: 300, height: 200)

private struct TestIntrinsicView: IntrinsicView {
    typealias Body = Never

    func sizeThatFits(_ proposal: ProposedSize) -> Size {
        Size(width: min(80, proposal.width ?? 80), height: 24)
    }

    func draw(in rect: Rect, context: RenderContext) {
        context.canvas.fillRect(rect, color: .black)
    }
}

private enum ClockKey: EnvironmentKey {
    static var defaultValue: Double { 0 }
}
extension EnvironmentValues {
    var clock: Double {
        get { self[ClockKey.self] }
        set { self[ClockKey.self] = newValue }
    }
}

@Test @XUIActor func drawLayerFillsAndReceivesResolvedRect() async {
    var painted = Rect.zero
    let view = DrawLayer { rect, _ in painted = rect }
        .frame(width: 120, height: 80, alignment: .topLeading)
    _ = await LayoutHost(canvas: canvas).render(view, into: RecordingCanvas())
    #expect(painted.isApproximately(Rect(x: 0, y: 0, width: 120, height: 80)))
}

@Test @XUIActor func drawLayerReadsInjectedEnvironment() async {
    var seenClock = -1.0
    var env = EnvironmentValues()
    env.clock = 42
    let view = DrawLayer { _, context in seenClock = context.environment.clock }
    _ = await LayoutHost(canvas: canvas, environment: env).render(view, into: RecordingCanvas())
    #expect(seenClock == 42)
}

@Test @XUIActor func drawLayerCanPaintThroughTheThinCanvas() async {
    let view = DrawLayer { rect, context in
        context.canvas.fillRect(rect, color: .black)
    }
    let surface = RecordingCanvas()
    _ = await LayoutHost(canvas: canvas).render(view, into: surface)
    #expect(surface.fills.count == 1)
    #expect(surface.fills[0].rect.isApproximately(Rect(x: 0, y: 0, width: 300, height: 200)))
}

@Test @XUIActor func drawLayerEmitsHitRegionsForSubAreas() async {
    let view = DrawLayer { rect, context in
        // three stacked hitboxes computed by the leaf itself
        for i in 0..<3 {
            let slice = Rect(x: rect.x, y: rect.y + Double(i) * 40, width: rect.width, height: 40)
            context.hitRegion(slice, i)
        }
    }
    .frame(width: 100, height: 120, alignment: .topLeading)
    let s = RecordingCanvas()
    let result = await LayoutHost(canvas: canvas).render(view, into: s)
    #expect(result.regions.count == 3)
    #expect(result.hit(Point(x: 10, y: 50), as: Int.self) == 1)
}

@Test @XUIActor func drawLayerWithExplicitSizeParticipatesInStackDistribution() async {
    let view = HStack(spacing: 0) {
        DrawLayer(size: { _ in Size(width: 60, height: 30) }) { _, _ in }
        Color.white
    }
    let surface = RecordingCanvas()
    _ = await LayoutHost(canvas: canvas).render(view, into: surface)
    // The sized DrawLayer paints nothing; only the Color records a fill.
    #expect(surface.fills.count == 1)
    #expect(surface.fills[0].rect.isApproximately(Rect(x: 60, y: 0, width: 240, height: 200)))
}

@Test @XUIActor func intrinsicViewOwnsItsSizingAndPaintWithoutADrawLayerWrapper() async {
    let surface = RecordingCanvas()
    _ = await LayoutHost(canvas: canvas)
        .render(TestIntrinsicView().frame(width: 60, alignment: .topLeading), into: surface)

    #expect(surface.fills.count == 1)
    #expect(surface.fills[0].rect.isApproximately(Rect(x: 0, y: 0, width: 60, height: 24)))
}
