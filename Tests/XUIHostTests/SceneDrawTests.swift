import Testing
import XRender
@testable import XUI
@testable import XUIHost

private enum ClockKey: XUI.EnvironmentKey {
    static var defaultValue: Double { 0 }
}

@Test func sceneDrawGetsRealBuilderAndEnvironment() {
    var env = XUI.EnvironmentValues()
    env[ClockKey.self] = 7

    let view = SceneDraw { rect, builder, context in
        // full SceneBuilder API, not just the thin XCanvas
        builder.verticalGradient(rect.render, top: RenderColor(1, 0, 0), bottom: RenderColor(0, 0, 1))
        #expect(context.environment[ClockKey.self] == 7)
    }
    .frame(width: 200, height: 100, alignment: .topLeading)

    let surface = SceneCanvas(size: RenderSize(width: 300, height: 200))
    LayoutHost(canvas: XUI.Size(width: 300, height: 200), environment: env)
        .render(view, into: surface)

    let hasGradient = surface.scene.commands.contains { command in
        if case .shape(let shape) = command, case .verticalGradient = shape.geometry { return true }
        return false
    }
    #expect(hasGradient)
}

@Test func sceneDrawAnchorStillExports() {
    let view = SceneDraw { _, _, _ in }
        .frame(width: 80, height: 60, alignment: .topLeading)
        .anchor("screen")
    let surface = SceneCanvas(size: RenderSize(width: 300, height: 200))
    let result = LayoutHost(canvas: XUI.Size(width: 300, height: 200)).render(view, into: surface)
    #expect(result.anchors["screen"] == XUI.Rect(x: 0, y: 0, width: 80, height: 60))
}

@Test func sceneDrawUsesItsResolvedOriginAsTheLocalOrigin() {
    let view = HStack(spacing: 0) {
        Color.clear.frame(width: 50, height: 40)
        SceneDraw { rect, builder, context in
            builder.rect(rect.render, color: RenderColor(1, 0, 0))
            context.hitRegion(XUI.Rect(x: 1, y: 2, width: 5, height: 6), "local")
        }
        .frame(width: 20, height: 10)
    }
    let surface = SceneCanvas(size: RenderSize(width: 300, height: 200))
    let result = LayoutHost(canvas: XUI.Size(width: 300, height: 200)).render(view, into: surface)

    let shape = surface.scene.commands.compactMap { command -> ShapeCommand? in
        if case .shape(let shape) = command, shape.color == RenderColor(1, 0, 0) { return shape }
        return nil
    }.first
    guard let shape, case .rect(let rect, _) = shape.geometry else {
        Issue.record("expected the SceneDraw rect")
        return
    }
    #expect(rect == RenderRect(x: 0, y: 0, width: 20, height: 10))
    #expect(shape.transform == Transform2D.translation(x: 50, y: 15))
    #expect(result.regions.first?.rect == XUI.Rect(x: 51, y: 17, width: 5, height: 6))
}
