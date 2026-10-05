import Testing
@testable import XUI

private let scrollCanvas = Size(width: 100, height: 200)

@XUIActor
private func renderScrollView(store: StateStore) async -> (RecordingCanvas, RenderResult) {
    let view = ScrollView {
        VStack(spacing: 0) {
            Color.red.frame(width: 100, height: 100)
            Color.green.frame(width: 100, height: 100)
            Color.blue.frame(width: 100, height: 100)
        }
    }
    let surface = RecordingCanvas()
    let result = await LayoutHost(canvas: scrollCanvas).render(view, into: surface, store: store)
    return (surface, result)
}

@Test @XUIActor
func scrollViewMeasuresContentBeyondItsViewport() async {
    let (surface, result) = await renderScrollView(store: StateStore())

    #expect(result.dragGestures.count == 1)
    #expect(surface.fills.map(\.rect) == [
        Rect(x: 0, y: 0, width: 100, height: 100),
        Rect(x: 0, y: 100, width: 100, height: 100),
        Rect(x: 0, y: 200, width: 100, height: 100),
    ])
}

@Test @XUIActor
func scrollViewMovesContentWhenDraggedUp() async {
    let store = StateStore()
    let (_, initial) = await renderScrollView(store: store)
    var runtime = GestureRuntime()

    #expect(runtime.handle(
        PointerInput(id: 1, phase: .began, position: Point(x: 50, y: 100)),
        in: initial
    ))
    #expect(runtime.handle(
        PointerInput(id: 1, phase: .moved, position: Point(x: 50, y: 40)),
        in: initial
    ))
    #expect(runtime.handle(
        PointerInput(id: 1, phase: .ended, position: Point(x: 50, y: 40)),
        in: initial
    ))

    let (surface, _) = await renderScrollView(store: store)
    #expect(surface.fills.map(\.rect) == [
        Rect(x: 0, y: -60, width: 100, height: 100),
        Rect(x: 0, y: 40, width: 100, height: 100),
        Rect(x: 0, y: 140, width: 100, height: 100),
    ])
}
