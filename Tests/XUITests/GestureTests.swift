import Testing
@testable import XUI

private let gestureCanvas = Size(width: 300, height: 200)

private final class SendableDragRecorder: @unchecked Sendable {
    var changed: [DragGestureValue] = []
    var ended: [DragGestureValue] = []
}

@XUIActor
private func renderGestureView(_ view: some XView) async -> RenderResult {
    await LayoutHost(canvas: gestureCanvas).render(view, into: RecordingCanvas())
}

@Test @XUIActor func dragGestureWaitsForMinimumDistanceAndEmitsTranslation() async {
    let recorder = SendableDragRecorder()
    let view = Color.black
        .frame(width: 100, height: 100, alignment: .topLeading)
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { recorder.changed.append($0) }
                .onEnded { recorder.ended.append($0) }
        )
    let render = await renderGestureView(view)
    var runtime = GestureRuntime()

    let began = runtime.handle(PointerInput(id: 7, phase: .began, position: Point(x: 10, y: 10)), in: render)
    #expect(began)
    let beforeThreshold = runtime.handle(PointerInput(id: 7, phase: .moved, position: Point(x: 15, y: 15), timestamp: 1), in: render)
    #expect(beforeThreshold)
    #expect(recorder.changed.isEmpty)
    let changed = runtime.handle(PointerInput(id: 7, phase: .moved, position: Point(x: 25, y: 10), timestamp: 2), in: render)
    #expect(changed)
    #expect(recorder.changed.count == 1)
    #expect(recorder.changed[0].translation == Point(x: 15, y: 0))
    let ended = runtime.handle(PointerInput(id: 7, phase: .ended, position: Point(x: 30, y: 20), timestamp: 3), in: render)
    #expect(ended)
    #expect(recorder.ended.count == 1)
    #expect(recorder.ended[0].translation == Point(x: 20, y: 10))
}

@Test @XUIActor func dragGestureCapturesPointerAndCancelsCleanly() async {
    let recorder = SendableDragRecorder()
    let view = Color.black
        .frame(width: 100, height: 100, alignment: .topLeading)
        .gesture(DragGesture(minimumDistance: 0).onEnded { recorder.ended.append($0) })
    let render = await renderGestureView(view)
    var runtime = GestureRuntime()

    let began = runtime.handle(PointerInput(id: 3, phase: .began, position: Point(x: 5, y: 5)), in: render)
    #expect(began)
    let wrongPointer = runtime.handle(PointerInput(id: 4, phase: .moved, position: Point(x: 200, y: 200)), in: render)
    #expect(!wrongPointer)
    let cancelled = runtime.handle(PointerInput(id: 3, phase: .cancelled, position: Point(x: 20, y: 20)), in: render)
    #expect(cancelled)
    #expect(recorder.ended.isEmpty)
    let endedAfterCancel = runtime.handle(PointerInput(id: 3, phase: .ended, position: Point(x: 20, y: 20)), in: render)
    #expect(!endedAfterCancel)
}
