import Testing
import XRender
import XUI
@testable import XUIHost

private final class HostDragRecorder: @unchecked Sendable {
    var ended: [DragGestureValue] = []
}

@Test @XUIActor func hostRendersAnXViewIntoAFrame() async {
    let host = XUIHost(size: RenderSize(width: 320, height: 180))
    let frame = await host.render(Color.red, time: 1.25)

    #expect(frame.scene.commands.count == 1)
    #expect(frame.scene.authoringCanvas == RenderSize(width: 320, height: 180))
    #expect(frame.layout.regions.isEmpty)
}

@Test @XUIActor func hostKeepsStateStoreAcrossFrames() async {
    let host = XUIHost(size: RenderSize(width: 320, height: 180))
    _ = await host.render(Color.blue, time: 1)
    let frame = await host.render(Color.green, time: 2)

    #expect(frame.scene.commands.count == 1)
}

@Test @XUIActor func hostRoutesPointerEventsIntoXUIGestures() async {
    let recorder = HostDragRecorder()
    let host = XUIHost(size: RenderSize(width: 320, height: 180))
    let frame = await host.render(
        Color.black
            .frame(width: 100, height: 100, alignment: .topLeading)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { recorder.ended.append($0) }
            )
    )

    let began = host.pointer(
        PointerEvent(
            id: 4,
            phase: .began,
            position: RenderPoint(x: 10, y: 10),
            timestamp: 1
        ),
        in: frame
    )
    #expect(began)

    let ended = host.pointer(
        PointerEvent(
            id: 4,
            phase: .ended,
            position: RenderPoint(x: 30, y: 25),
            timestamp: 2
        ),
        in: frame
    )
    #expect(ended)
    #expect(recorder.ended.count == 1)
    #expect(recorder.ended[0].translation == Point(x: 20, y: 15))
    #expect(recorder.ended[0].time == 2)
}
