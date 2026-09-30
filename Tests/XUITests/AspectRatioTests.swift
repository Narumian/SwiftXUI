import Testing
@testable import XUI

private func frames(_ view: some XView, canvas: Size = Size(width: 300, height: 200)) -> [Rect] {
    let surface = RecordingCanvas()
    LayoutHost(canvas: canvas).render(view, into: surface)
    return surface.fills.map(\.rect)
}

private struct IdealFill: XView, _PrimitiveXView {
    typealias Body = Never
    var ideal: Size

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let node = LayoutNode(layout: FillLayout(ideal: ideal))
        node.draw = { rect, context in context.canvas.fillRect(rect, color: .black) }
        return [node]
    }
}

@Test func aspectRatioFitsInsideTheOfferedBox() {
    let view = Color.black
        .aspectRatio(16.0 / 9.0)
        .frame(width: 320, height: 320)
    let f = frames(view)
    #expect(f[0].isApproximately(Rect(x: 0, y: 70, width: 320, height: 180)))
}

@Test func aspectAliasMatchesAspectRatio() {
    let view = Color.black
        .aspect(2)
        .frame(width: 120, height: 120)
    let f = frames(view)
    #expect(f[0].isApproximately(Rect(x: 0, y: 30, width: 120, height: 60)))
}

@Test func aspectRatioHonoursAlignment() {
    let view = Color.black
        .aspectRatio(2, alignment: .bottomTrailing)
        .frame(width: 120, height: 120, alignment: .bottomTrailing)
    let f = frames(view)
    #expect(f[0].isApproximately(Rect(x: 0, y: 60, width: 120, height: 60)))
}

@Test func aspectRatioFillCoversTheOfferedBox() {
    let view = Color.black
        .aspectRatio(2, contentMode: .fill)
        .frame(width: 120, height: 120)
    let f = frames(view)
    #expect(f[0].isApproximately(Rect(x: -60, y: 0, width: 240, height: 120)))
}

@Test func scaledToFitUsesTheChildIdealAspect() {
    let view = IdealFill(ideal: Size(width: 160, height: 80))
        .scaledToFit()
        .frame(width: 100, height: 100)
    let f = frames(view)
    #expect(f[0].isApproximately(Rect(x: 0, y: 25, width: 100, height: 50)))
}
