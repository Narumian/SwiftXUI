import Testing
import XRender
import XShader
import XUI
@testable import XUIHost

// Official mini-recipes (§4.1). Each program is a copy-paste starting point;
// assertions lock the lowering contract so sugar and docs stay honest.

/// Particle buffer → fade trail pass → blit to output.
private struct ParticleTrailRecipe: X3DProgram {
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

/// Unit icosphere under a perspective camera via `MeshDraw`.
private struct IcosphereCameraRecipe: X3DProgram {
    var body: some X3DProgram {
        Camera(position: SIMD3(0, 0, 3)) {
            MeshDraw("lit", mesh: X3DMesh.icosphere(subdivisions: 1), blend: .opaque)
                .transform3D(.scale(0.8))
        }
    }
}

/// An `XView` inside `Camera` becomes a sized plane in world space.
private struct Plane2DIn3DRecipe: X3DProgram {
    var body: some X3DProgram {
        Camera(position: SIMD3(0, 0, 3)) {
            Color.red.frame(width: 40, height: 20)
                .transform3D(.translation(SIMD3(0, 1, 0)))
        }
    }
}

/// Instanced draw (declares transform buffer) plus a fullscreen post pass item.
private struct FullscreenAndInstancedRecipe: X3DProgram {
    var body: some X3DProgram {
        Instanced(
            "sprites",
            transforms: [.identity, .translation(SIMD3(1, 0, 0))],
            vertices: 6,
            blend: .additive
        )
        Fullscreen("post", blend: .opaque)
    }
}

@XUIActor
private func render<V: XView>(_ view: V) async -> Scene {
    let surface = SceneCanvas(size: RenderSize(width: 100, height: 50))
    _ = await LayoutHost(canvas: XUI.Size(width: 100, height: 50)).render(view, into: surface)
    return surface.scene
}

@Test @XUIActor func recipeParticleTrailLowersLikeFlow() async throws {
    let scene = await render(X3DView { ParticleTrailRecipe(energy: 0.5) })
    guard case .x3d(let command) = try #require(scene.commands.first) else {
        Issue.record("Expected an x3d command")
        return
    }
    let graph = command.graph
    #expect(graph.resources.count == 2)
    #expect(graph.passes.count == 3)
    guard case .compute(let step) = graph.passes[0],
          case .render(let fade) = graph.passes[1],
          case .render(let output) = graph.passes[2] else {
        Issue.record("Expected compute + fade + blit passes")
        return
    }
    #expect(step.entry == "step")
    #expect(fade.load == .fade(0.1))
    #expect(output.items == [.blit(graph.resources[1].id, blend: .alpha)])
}

@Test @XUIActor func recipeIcosphereCameraUsesMeshDraw() async throws {
    let mesh = X3DMesh.icosphere(subdivisions: 1)
    let scene = await render(X3DView { IcosphereCameraRecipe() })
    guard case .x3d(let command) = try #require(scene.commands.first),
          case .buffer(_, let byteCount, let contents) = try #require(command.graph.resources.first),
          case .render(let pass) = try #require(command.graph.passes.first),
          case .draw(let draw) = try #require(pass.items.first) else {
        Issue.record("Expected mesh buffer + draw")
        return
    }
    #expect(byteCount == mesh.count * MemoryLayout<Float>.stride)
    #expect(contents == mesh)
    #expect(draw.vertexCount == mesh.count / X3DMesh.floatsPerVertex)
    #expect(draw.camera?.position == SIMD3(0, 0, 3))
    #expect(draw.model == .scale(0.8))
    #expect(draw.bindings.count == 1)
    #expect(draw.bindings[0].resource.name == "mesh")
}

@Test @XUIActor func recipePlane2DIn3DIsACameraPlane() async throws {
    let scene = await render(X3DView { Plane2DIn3DRecipe() })
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
}

@Test @XUIActor func recipeFullscreenAndInstancedLower() async throws {
    let scene = await render(X3DView { FullscreenAndInstancedRecipe() })
    guard case .x3d(let command) = try #require(scene.commands.first) else {
        Issue.record("Expected an x3d command")
        return
    }
    #expect(command.graph.resources.count == 1)
    guard case .buffer(let id, let byteCount, let contents) = command.graph.resources[0],
          case .render(let pass) = try #require(command.graph.passes.first) else {
        Issue.record("Expected instance buffer + one pass")
        return
    }
    #expect(id.name == "instances")
    #expect(byteCount == 128)
    #expect(contents?.count == 32)
    #expect(pass.items.count == 2)
    guard case .draw(let instanced) = pass.items[0],
          case .draw(let fullscreen) = pass.items[1] else {
        Issue.record("Expected instanced then fullscreen draws")
        return
    }
    #expect(instanced.vertexCount == 6)
    #expect(instanced.instanceCount == 2)
    #expect(instanced.bindings.map(\.resource.name) == ["instances"])
    #expect(fullscreen.vertexCount == 3)
    #expect(fullscreen.instanceCount == 1)
    #expect(fullscreen.bindings.isEmpty)
}

@Test @XUIActor func meshDrawExtraBindsAppendAfterMesh() async throws {
    let scene = await render(
        X3DView {
            Texture("albedo")
            MeshDraw("lit", mesh: [0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0])
                .bind("albedo")
        }
    )
    guard case .x3d(let command) = try #require(scene.commands.first),
          case .render(let pass) = try #require(command.graph.passes.first),
          case .draw(let draw) = try #require(pass.items.first) else {
        Issue.record("Expected a mesh draw")
        return
    }
    #expect(draw.vertexCount == 3)
    #expect(draw.bindings.map(\.resource.name) == ["mesh", "albedo"])
}

@Test @XUIActor func recipeDiagnoseFlagsUnregisteredShader() async throws {
    let scene = await render(X3DView { ParticleTrailRecipe(energy: 0.25) })
    guard case .x3d(let command) = try #require(scene.commands.first) else {
        Issue.record("Expected an x3d command")
        return
    }
    let missing = command.graph.diagnose(registeredShaders: [])
    #expect(missing.contains { diagnostic in
        if case .unregisteredShader(let key) = diagnostic.kind { return key == "flow" }
        return false
    })
    #expect(command.graph.diagnose(registeredShaders: ["flow"]).isEmpty)
}
