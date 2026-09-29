import Testing
@testable import SwiftXUI

private let canvas = Size(width: 300, height: 200)

private func render(_ view: some XView) -> RecordingCanvas {
    let surface = RecordingCanvas()
    LayoutHost(canvas: canvas).render(view, into: surface)
    return surface
}

@Test func borderDrawsOverTheContentWithoutChangingLayout() {
    let surface = render(
        Color.white
            .frame(width: 80, height: 40)
            .border(.black, width: 4)
    )

    #expect(surface.fills[0].rect == Rect(x: 0, y: 0, width: 80, height: 40))
    #expect(surface.strokes[0].rect == Rect(x: 2, y: 2, width: 76, height: 36))
    #expect(surface.strokes[0].lineWidth == 4)
}

@Test func borderCanUseACornerRadius() {
    let surface = render(
        Color.white
            .frame(width: 80, height: 40)
            .border(.red, width: 2, cornerRadius: 8)
    )

    #expect(surface.strokes[0].color == .red)
    #expect(surface.strokes[0].cornerRadius == 7)
}
