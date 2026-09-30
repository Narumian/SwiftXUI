import Testing
@testable import XUI

private let canvas = Size(width: 300, height: 200)

private func render(_ view: some XView) -> RecordingCanvas {
    let surface = RecordingCanvas()
    LayoutHost(canvas: canvas).render(view, into: surface)
    return surface
}

@Test func pathKeepsItsAuthoredBoundsAndFillsTheRootProposal() {
    let path = Path { p in
        p.move(to: Point(x: 10, y: 20))
        p.addLine(to: Point(x: 90, y: 20))
        p.addLine(to: Point(x: 90, y: 50))
        p.closeSubpath()
    }

    let surface = render(path)
    #expect(path.bounds == Rect(x: 10, y: 20, width: 80, height: 30))
    #expect(surface.paths[0].rect == Rect(x: 0, y: 0, width: 300, height: 200))
}

@Test func pathCanBeStrokedInAResolvedFrame() {
    let path = Path(points: [
        Point(x: 0, y: 0),
        Point(x: 1, y: 0),
        Point(x: 1, y: 1)
    ], closed: false)
    let surface = render(path.stroke(.white, lineWidth: 4).frame(width: 120, height: 60))

    #expect(surface.paths[0].rect == Rect(x: 0, y: 0, width: 120, height: 60))
    #expect(surface.paths[0].color == .white)
    #expect(surface.paths[0].lineWidth == 4)
}

@Test func pathSubpathsFitAuthoredPointsIntoDestinationRect() {
    let path = Path(points: [
        Point(x: 10, y: 20),
        Point(x: 30, y: 20),
        Point(x: 30, y: 60)
    ])
    let subpaths = path.subpaths(fittedIn: Rect(x: 100, y: 50, width: 200, height: 80))

    #expect(subpaths.count == 1)
    #expect(subpaths[0].closed)
    #expect(subpaths[0].points == [
        Point(x: 100, y: 50),
        Point(x: 300, y: 50),
        Point(x: 300, y: 130)
    ])
}
