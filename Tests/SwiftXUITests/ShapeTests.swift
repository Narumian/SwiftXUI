import Testing
@testable import SwiftXUI

private let canvas = Size(width: 300, height: 200)

private func render(_ view: some XView) -> RecordingCanvas {
    let surface = RecordingCanvas()
    LayoutHost(canvas: canvas).render(view, into: surface)
    return surface
}

@Test func rectangleFillsItsResolvedFrame() {
    let surface = render(Rectangle(fill: .white).frame(width: 80, height: 40, alignment: .topLeading))
    #expect(surface.fills[0].rect == Rect(x: 0, y: 0, width: 80, height: 40))
    #expect(surface.fills[0].color == .white)
}

@Test func roundedRectangleCarriesCornerRadius() {
    let surface = render(RoundedRectangle(cornerRadius: 9, fill: .black).frame(width: 70, height: 30))
    #expect(surface.fills[0].rect == Rect(x: 0, y: 0, width: 70, height: 30))
    #expect(surface.fills[0].cornerRadius == 9)
}

@Test func ellipseFillsItsResolvedFrame() {
    let surface = render(Ellipse(fill: .white).frame(width: 60, height: 24))
    #expect(surface.ellipses[0].rect == Rect(x: 0, y: 0, width: 60, height: 24))
    #expect(surface.ellipses[0].color == .white)
}

@Test func circleFitsInsideTheOfferedFrame() {
    let surface = render(Circle(fill: .white).frame(width: 80, height: 40))
    #expect(surface.ellipses[0].rect == Rect(x: 20, y: 0, width: 40, height: 40))
}
