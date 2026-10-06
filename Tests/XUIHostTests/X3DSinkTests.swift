import Testing
import XRender
import XShader
import XUI
@testable import XUIHost

private struct Flow: X3DProgram {
    var energy: Float
    var body: some X3DProgram {
        Buffer("particles", stride: 16, count: 4)
        Texture("trail")
        Compute("flow", entry: "step", threads: 4, uniforms: [energy])
            .bind("particles")
        Pass(into: "trail", load: .fade(0.1)) {
            Draw("flow", vertices: 6, instances: 4, blend: .additive)
                .bind("particles")
        }
        Blit("trail")
    }
}

@XUIActor
private func render<V: XView>(_ view: V) async -> Scene {
    let surface = SceneCanvas(size: RenderSize(width: 100, height: 50))
    _ = await LayoutHost(canvas: XUI.Size(width: 100, height: 50)).render(view, into: surface)
    return surface.scene
}

@Test @XUIActor func x3dViewLowersProgramToGraph() async throws {
    let scene = await render(X3DView { Flow(energy: 0.5) })
    #expect(scene.commands.count == 1)
    guard case .x3d(let command) = try #require(scene.commands.first) else {
        Issue.record("Expected an x3d command")
        return
    }
    #expect(command.rect == RenderRect(x: 0, y: 0, width: 100, height: 50))
    let graph = command.graph
    let particles = graph.resources[0].id
    let trail = graph.resources[1].id
    #expect(particles.name == "particles")
    #expect(particles.scope == trail.scope)
    #expect(graph.resources[0] == .buffer(id: particles, byteCount: 64))
    #expect(graph.passes.count == 3)
    #expect(graph.passes[0] == .compute(X3DCompute(
        shader: "flow", entry: "step", threads: 4,
        bindings: [X3DBinding(resource: particles, access: .readWrite)], uniforms: [0.5]
    )))
    guard case .render(let fade) = graph.passes[1], case .render(let output) = graph.passes[2] else {
        Issue.record("Expected two render passes")
        return
    }
    #expect(fade.target == .texture(trail))
    #expect(fade.load == .fade(0.1))
    #expect(fade.items.count == 1)
    #expect(output.target == .output)
    #expect(output.items == [.blit(trail, blend: .alpha)])
}

@Test @XUIActor func embeddedViewsBecomeViewItemsInPaintOrder() async throws {
    let scene = await render(
        X3DView {
            Draw("bg", vertices: 3)
            Color.red.frame(width: 10, height: 10)
            Draw("fg", vertices: 3)
        }
    )
    #expect(scene.commands.count == 1)
    guard case .x3d(let command) = try #require(scene.commands.first),
          case .render(let pass) = try #require(command.graph.passes.first) else {
        Issue.record("Expected one implicit output pass")
        return
    }
    #expect(command.graph.passes.count == 1)
    #expect(pass.target == .output)
    #expect(pass.items.count == 3)
    guard case .view(let rect, let commands) = pass.items[1] else {
        Issue.record("Expected the embedded view between the draws")
        return
    }
    #expect(rect == RenderRect(x: 45, y: 20, width: 10, height: 10))
    #expect(commands.count == 1)
    #expect(command.graph.viewCommands.count == 1)
}

@Test @XUIActor func twoInstancesOfAProgramDoNotShareResources() async throws {
    let scene = await render(
        HStack(spacing: 0) {
            X3DView { Flow(energy: 0) }
            X3DView { Flow(energy: 1) }
        }
    )
    let scopes = scene.commands.compactMap { command -> Int? in
        guard case .x3d(let x3d) = command else { return nil }
        return x3d.graph.resources.first?.id.scope
    }
    #expect(scopes.count == 2)
    #expect(scopes[0] != scopes[1])
}

@Test func compilerMapsX3DToPixelsAndCompilesViews() {
    let view = X3DRenderItem.view(rect: RenderRect(x: 0, y: 0, width: 10, height: 10), commands: [
        .shape(ShapeCommand(geometry: .rect(RenderRect(x: 0, y: 0, width: 10, height: 10), corner: 0),
                            color: RenderColor(1, 0, 0, 1)))
    ])
    let graph = X3DGraph(passes: [.render(X3DRenderPass(target: .output, load: .load, items: [view]))])
    let scene = Scene(commands: [.x3d(X3DCommand(rect: RenderRect(x: 0, y: 0, width: 50, height: 25), graph: graph))],
                      authoringCanvas: RenderSize(width: 100, height: 50))
    let frame = SceneCompiler.compile(scene, canvas: RenderSize(width: 100, height: 50),
                                      framebuffer: RenderSize(width: 200, height: 100))
    #expect(frame.draws == [.x3d(index: 0)])
    #expect(frame.x3d[0].rect == PixelRect(x: 0, y: 0, width: 100, height: 50))
    #expect(frame.x3d[0].views.count == 1)
    #expect(!frame.x3d[0].views[0].shapeVertices.isEmpty)
}

@Test @XUIActor func drawsCarryTheirCameraAndComposedTransform() async throws {
    let scene = await render(
        X3DView {
            Camera(position: SIMD3(0, 0, 3)) {
                Draw("mesh", vertices: 3)
                    .transform3D(.scale(2))
                    .transform3D(.translation(SIMD3(1, 0, 0)))
            }
        }
    )
    guard case .x3d(let command) = try #require(scene.commands.first),
          case .render(let pass) = try #require(command.graph.passes.first),
          case .draw(let draw) = try #require(pass.items.first) else {
        Issue.record("Expected one draw")
        return
    }
    #expect(draw.camera?.position == SIMD3(0, 0, 3))
    #expect(draw.model == .translation(SIMD3(1, 0, 0)) * .scale(2))
}

@Test @XUIActor func viewsInsideACameraBecomePlanesOfTheirOwnSize() async throws {
    let scene = await render(
        X3DView {
            Camera(position: SIMD3(0, 0, 3)) {
                Color.red.frame(width: 40, height: 20)
                    .transform3D(.translation(SIMD3(0, 1, 0)))
            }
        }
    )
    guard case .x3d(let command) = try #require(scene.commands.first),
          case .render(let pass) = try #require(command.graph.passes.first),
          case .plane(let size, let commands, let camera, let model) = try #require(pass.items.first) else {
        Issue.record("Expected a plane")
        return
    }
    #expect(size == RenderSize(width: 40, height: 20))
    #expect(commands.count == 1)
    #expect(camera.position == SIMD3(0, 0, 3))
    #expect(model == .translation(SIMD3(0, 1, 0)))

    let frame = SceneCompiler.compile(scene, canvas: RenderSize(width: 100, height: 50),
                                      framebuffer: RenderSize(width: 100, height: 50))
    #expect(frame.x3d[0].planes.count == 1)
    #expect(frame.x3d[0].planes[0].uv == SIMD4(0, 0, 1, 1))
}

@Test @XUIActor func transformBuffersFlattenOneMatrixPerInstance() async throws {
    let scene = await render(
        X3DView { Buffer("instances", transforms: [.identity, .translation(SIMD3(1, 2, 3))]) }
    )
    guard case .x3d(let command) = try #require(scene.commands.first),
          case .buffer(_, let byteCount, let contents, _) = try #require(command.graph.resources.first) else {
        Issue.record("Expected a buffer")
        return
    }
    #expect(byteCount == 128)
    #expect(contents?.count == 32)
    #expect(contents?[28...30] == [1, 2, 3])
}
