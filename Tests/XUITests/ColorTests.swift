import Testing
@testable import XUI

private let canvas = Size(width: 300, height: 200)

@XUIActor
private func render(_ view: some XView) async -> RecordingCanvas {
    let surface = RecordingCanvas()
    await LayoutHost(canvas: canvas).render(view, into: surface)
    return surface
}

@Test @XUIActor func colorCanBeCreatedFromHex() async {
    let color = XColorValue(hex: 0xff8040, opacity: 0.5)

    #expect(color.red == 1)
    #expect(abs(color.green - 128.0 / 255.0) < 0.0001)
    #expect(abs(color.blue - 64.0 / 255.0) < 0.0001)
    #expect(color.opacity == 0.5)
}

@Test @XUIActor func colorAddsBasicNamedColors() async {
    let surface = await render(Color.blue.frame(width: 10, height: 10))

    #expect(surface.fills[0].color == .blue)
}
