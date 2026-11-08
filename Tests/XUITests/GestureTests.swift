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

@Test @XUIActor func dragWithNoMinimumDistanceReportsTheTouchDownBeforeAnyMovement() async {
    let recorder = SendableDragRecorder()
    let view = Color.black
        .frame(width: 100, height: 100, alignment: .topLeading)
        .gesture(DragGesture(minimumDistance: 0).onChanged { recorder.changed.append($0) }.onEnded { recorder.ended.append($0) })
    let render = await renderGestureView(view)
    var runtime = GestureRuntime()

    _ = runtime.handle(PointerInput(id: 1, phase: .began, position: Point(x: 10, y: 10), timestamp: 1), in: render)
    #expect(recorder.changed.count == 1)
    #expect(recorder.changed[0].translation == Point(x: 0, y: 0))
    #expect(recorder.ended.isEmpty)
    _ = runtime.handle(PointerInput(id: 1, phase: .ended, position: Point(x: 10, y: 10), timestamp: 2), in: render)
    #expect(recorder.ended.count == 1)
}

private final class LongPressRecorder: @unchecked Sendable {
    var taps = 0
    var longPresses = 0
}

@Test @XUIActor func longPressFiresOnReleaseAfterTheMinimumDurationAndReplacesTheTap() async {
    let recorder = LongPressRecorder()
    let view = Color.black
        .frame(width: 100, height: 100, alignment: .topLeading)
        .onTapGesture { recorder.taps += 1 }
        .onLongPressGesture(minimumDuration: 0.5) { recorder.longPresses += 1 }
    let render = await renderGestureView(view)
    var runtime = GestureRuntime()

    _ = runtime.handle(PointerInput(phase: .began, position: Point(x: 10, y: 10), timestamp: 10), in: render)
    _ = runtime.handle(PointerInput(phase: .ended, position: Point(x: 10, y: 10), timestamp: 10.2), in: render)
    #expect(recorder.taps == 1 && recorder.longPresses == 0)

    _ = runtime.handle(PointerInput(phase: .began, position: Point(x: 10, y: 10), timestamp: 20), in: render)
    _ = runtime.handle(PointerInput(phase: .ended, position: Point(x: 10, y: 10), timestamp: 20.5), in: render)
    #expect(recorder.taps == 1 && recorder.longPresses == 1)
}

@Test @XUIActor func longPressNeedsRealTimestampsAndAStationaryPointer() async {
    let recorder = LongPressRecorder()
    let view = Color.black
        .frame(width: 100, height: 100, alignment: .topLeading)
        .onLongPressGesture(minimumDuration: 0.5) { recorder.longPresses += 1 }
    let render = await renderGestureView(view)
    var runtime = GestureRuntime(tapSlop: 10)

    // A host that sends no timestamps (all 0) never produces a long press.
    _ = runtime.handle(PointerInput(phase: .began, position: Point(x: 10, y: 10)), in: render)
    _ = runtime.handle(PointerInput(phase: .ended, position: Point(x: 10, y: 10)), in: render)
    #expect(recorder.longPresses == 0)

    // Moving past the slop while held is not a long press.
    _ = runtime.handle(PointerInput(phase: .began, position: Point(x: 10, y: 10), timestamp: 5), in: render)
    _ = runtime.handle(PointerInput(phase: .moved, position: Point(x: 60, y: 10), timestamp: 5.2), in: render)
    _ = runtime.handle(PointerInput(phase: .ended, position: Point(x: 60, y: 10), timestamp: 6), in: render)
    #expect(recorder.longPresses == 0)

    // A cancelled hold does nothing.
    _ = runtime.handle(PointerInput(phase: .began, position: Point(x: 10, y: 10), timestamp: 8), in: render)
    _ = runtime.handle(PointerInput(phase: .cancelled, position: Point(x: 10, y: 10), timestamp: 9), in: render)
    #expect(recorder.longPresses == 0)
}

@Test @XUIActor func aDragStartedOnALongPressViewSuppressesIt() async {
    let recorder = LongPressRecorder()
    let view = Color.black
        .frame(width: 100, height: 100, alignment: .topLeading)
        .gesture(DragGesture(minimumDistance: 4).onChanged { _ in })
        .onLongPressGesture(minimumDuration: 0.5) { recorder.longPresses += 1 }
    let render = await renderGestureView(view)
    var runtime = GestureRuntime()
    _ = runtime.handle(PointerInput(phase: .began, position: Point(x: 10, y: 10), timestamp: 1), in: render)
    _ = runtime.handle(PointerInput(phase: .moved, position: Point(x: 30, y: 10), timestamp: 1.1), in: render)
    _ = runtime.handle(PointerInput(phase: .ended, position: Point(x: 30, y: 10), timestamp: 2), in: render)
    #expect(recorder.longPresses == 0)
}
