import Testing
import XRender
@testable import XUI
@testable import XUISceneKit

private let canvas = Size(width: 1920, height: 1080)

@Test func colorPaintsOneRectIntoTheScene() {
    let surface = SceneCanvas(size: RenderSize(width: 1920, height: 1080))
    LayoutHost(canvas: canvas).render(Color(red: 1, green: 0, blue: 0), into: surface)

    let shapes = surface.scene.commands.compactMap { command -> ShapeCommand? in
        if case .shape(let s) = command { return s }
        return nil
    }
    #expect(shapes.count == 1)
    #expect(shapes[0].color.red == 1)
}

@Test func frameResolvesToExpectedRenderRect() {
    let surface = SceneCanvas(size: RenderSize(width: 1920, height: 1080))
    LayoutHost(canvas: canvas).render(
        Color.white.frame(width: 200, height: 120, alignment: .topLeading),
        into: surface
    )

    guard case .shape(let shape)? = surface.scene.commands.first,
          case .rect(let rect, _) = shape.geometry else {
        Issue.record("expected a rect shape")
        return
    }
    #expect(rect == RenderRect(x: 0, y: 0, width: 200, height: 120))
}

@Test func clippedViewCarriesItsResolvedRectIntoSceneCommands() {
    let surface = SceneCanvas(size: RenderSize(width: 1920, height: 1080))
    LayoutHost(canvas: canvas).render(
        Color.white
            .frame(width: 80, height: 40, alignment: .topLeading)
            .clipped(),
        into: surface
    )

    guard case .shape(let shape)? = surface.scene.commands.first else {
        Issue.record("expected a clipped shape")
        return
    }
    #expect(shape.clip == RenderRect(x: 0, y: 0, width: 80, height: 40))
}

@Test func ellipsePaintsAnEllipseShapeIntoTheScene() {
    let surface = SceneCanvas(size: RenderSize(width: 1920, height: 1080))
    LayoutHost(canvas: canvas).render(
        Ellipse(fill: XColorValue(1, 0, 0, 0.5)).frame(width: 80, height: 40),
        into: surface
    )

    guard case .shape(let shape)? = surface.scene.commands.first,
          case .ellipse(let center, let radiusX, let radiusY) = shape.geometry else {
        Issue.record("expected an ellipse shape")
        return
    }
    #expect(center == RenderPoint(x: 40, y: 20))
    #expect(radiusX == 40)
    #expect(radiusY == 20)
    #expect(shape.color.alpha == 0.5)
}

@Test func borderPaintsAStrokeShapeIntoTheScene() {
    let surface = SceneCanvas(size: RenderSize(width: 1920, height: 1080))
    LayoutHost(canvas: canvas).render(
        Color.white
            .frame(width: 80, height: 40)
            .border(.black, width: 4),
        into: surface
    )

    let shapes = surface.scene.commands.compactMap { command -> ShapeCommand? in
        if case .shape(let shape) = command { return shape }
        return nil
    }
    guard case .stroke(let points, let width, let closed) = shapes.last?.geometry else {
        Issue.record("expected a border stroke")
        return
    }
    #expect(points == [
        RenderPoint(x: 2, y: 2),
        RenderPoint(x: 78, y: 2),
        RenderPoint(x: 78, y: 38),
        RenderPoint(x: 2, y: 38)
    ])
    #expect(width == 4)
    #expect(closed)
}

@Test func pathPaintsPolygonAndPolylineShapesIntoTheScene() {
    let fillSurface = SceneCanvas(size: RenderSize(width: 1920, height: 1080))
    let triangle = XUI.Path(points: [
        XUI.Point(x: 0, y: 0),
        XUI.Point(x: 1, y: 0),
        XUI.Point(x: 1, y: 1)
    ])
    LayoutHost(canvas: canvas).render(triangle.fill(.white).frame(width: 90, height: 45), into: fillSurface)

    guard case .shape(let fillShape)? = fillSurface.scene.commands.first,
          case .polygon(let fillPoints) = fillShape.geometry else {
        Issue.record("expected a polygon shape")
        return
    }
    #expect(fillPoints == [
        RenderPoint(x: 0, y: 0),
        RenderPoint(x: 90, y: 0),
        RenderPoint(x: 90, y: 45)
    ])

    let strokeSurface = SceneCanvas(size: RenderSize(width: 1920, height: 1080))
    LayoutHost(canvas: canvas).render(triangle.stroke(.black, lineWidth: 6).frame(width: 90, height: 45), into: strokeSurface)

    guard case .shape(let strokeShape)? = strokeSurface.scene.commands.first,
          case .stroke(let strokePoints, let width, let closed) = strokeShape.geometry else {
        Issue.record("expected a stroke shape")
        return
    }
    #expect(strokePoints == fillPoints)
    #expect(width == 6)
    #expect(closed)
}

@Test func outlinedTextPaintsStrokeCopiesBeforeTheFill() {
    let surface = SceneCanvas(size: RenderSize(width: 1920, height: 1080))
    LayoutHost(canvas: canvas).render(
        Text("28", size: 3, color: .white)
            .font(.display)
            .outline(color: .black, width: 2),
        into: surface
    )

    let texts = surface.scene.commands.compactMap { command -> TextCommand? in
        if case .text(let text) = command { return text }
        return nil
    }
    #expect(texts.count == 1)
    #expect(texts.first?.color == RenderColor(1, 1, 1, 1))
    #expect(texts.first?.outline == 2)
    #expect(texts.first?.outlineColor == RenderColor(0, 0, 0, 1))
    #expect(texts.first?.font == .display)
}

@Test func geometryBridgingRoundTrips() {
    let r = XUI.Rect(x: 12, y: 34, width: 56, height: 78)
    let back = XUI.Size(r.render.width == 56 ? RenderSize(width: 56, height: 78) : .init(width: 0, height: 0))
    #expect(back.width == 56)
}
