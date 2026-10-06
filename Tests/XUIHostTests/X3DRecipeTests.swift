import Testing
import XRender
import XShader
import XUI
@testable import XUIHost

// Official mini-recipes (§4.1). Each program is a copy-paste starting point;
// assertions lock the lowering contract so sugar and docs stay honest.

/// Particle buffer → fade trail pass → blit to output (via `FeedbackTrail`).
private struct ParticleTrailRecipe: X3DProgram {
    var energy: Float
    var body: some X3DProgram {
        Buffer("particles", stride: 16, count: 4)
        Compute("flow", entry: "step", threads: 4, uniforms: [energy])
            .bind("particles")
        FeedbackTrail("trail", fade: 0.1) {
            Draw("flow", vertices: 6, instances: 4, blend: .additive)
                .bind("particles")
        }
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

/// Instanced mesh copies via `MeshDraw.instanced` (preferred mesh path).
private struct InstancedMeshRecipe: X3DProgram {
    var body: some X3DProgram {
        MeshDraw("lit", mesh: X3DMesh.icosphere(subdivisions: 0), blend: .opaque)
            .instanced(transforms: [.identity, .translation(SIMD3(1, 0, 0))])
    }
}

/// Shallow tilt card with interactive plane input (M2 product focus).
private struct TiltCardRecipe: X3DProgram {
    var tilt: Float
    var body: some X3DProgram {
        Camera(position: SIMD3(0, 0, 3), acceptsInput: true) {
            Color.blue.frame(width: 40, height: 20)
                .region("card")
                .transform3D(
                    .rotation(axis: SIMD3(0, 1, 0), angle: tilt)
                    * .rotation(axis: SIMD3(1, 0, 0), angle: tilt * 0.25)
                )
        }
    }
}

@XUIActor
private func render<V: XView>(_ view: V) async -> Scene {
    let surface = SceneCanvas(size: RenderSize(width: 100, height: 50))
    _ = await LayoutHost(canvas: XUI.Size(width: 100, height: 50)).render(view, into: surface)
    return surface.scene
}

@XUIActor
private func renderLayout<V: XView>(_ view: V) async -> RenderResult {
    let surface = SceneCanvas(size: RenderSize(width: 100, height: 50))
    return await LayoutHost(canvas: XUI.Size(width: 100, height: 50)).render(view, into: surface)
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
          case .buffer(_, let byteCount, let contents, _) = try #require(command.graph.resources.first),
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

@Test @XUIActor func recipeMeshDrawInstancedUploadsMeshAndTransforms() async throws {
    let mesh = X3DMesh.icosphere(subdivisions: 0)
    let scene = await render(X3DView { InstancedMeshRecipe() })
    guard case .x3d(let command) = try #require(scene.commands.first) else {
        Issue.record("Expected an x3d command")
        return
    }
    #expect(command.graph.resources.count == 2)
    guard case .buffer(let meshID, let meshBytes, let meshContents, _) = command.graph.resources[0],
          case .buffer(let instanceID, let instanceBytes, let instanceContents, _) = command.graph.resources[1],
          case .render(let pass) = try #require(command.graph.passes.first),
          case .draw(let draw) = try #require(pass.items.first) else {
        Issue.record("Expected mesh + instance buffers and one draw")
        return
    }
    #expect(meshID.name == "mesh")
    #expect(instanceID.name == "instances")
    #expect(meshBytes == mesh.count * MemoryLayout<Float>.stride)
    #expect(meshContents == mesh)
    #expect(instanceBytes == 128)
    #expect(instanceContents?.count == 32)
    #expect(draw.vertexCount == mesh.count / X3DMesh.floatsPerVertex)
    #expect(draw.instanceCount == 2)
    #expect(draw.bindings.map(\.resource.name) == ["mesh", "instances"])
}

@Test @XUIActor func fullscreenDrawUsesThreeVertices() async throws {
    let scene = await render(X3DView { Fullscreen("post", blend: .opaque) })
    guard case .x3d(let command) = try #require(scene.commands.first),
          case .render(let pass) = try #require(command.graph.passes.first),
          case .draw(let draw) = try #require(pass.items.first) else {
        Issue.record("Expected a fullscreen draw")
        return
    }
    #expect(draw.vertexCount == 3)
    #expect(draw.bindings.isEmpty)
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
    var env = EnvironmentValues()
    env.x3dRegisteredShaders = []
    let surface = SceneCanvas(size: RenderSize(width: 100, height: 50))
    let layout = await LayoutHost(canvas: XUI.Size(width: 100, height: 50), environment: env)
        .render(X3DView { ParticleTrailRecipe(energy: 0.25) }, into: surface)
    #expect(layout.x3dDiagnostics.contains { diagnostic in
        if case .unregisteredShader(let key) = diagnostic.kind { return key == "flow" }
        return false
    })

    env.x3dRegisteredShaders = ["flow"]
    let okSurface = SceneCanvas(size: RenderSize(width: 100, height: 50))
    let ok = await LayoutHost(canvas: XUI.Size(width: 100, height: 50), environment: env)
        .render(X3DView { ParticleTrailRecipe(energy: 0.25) }, into: okSurface)
    #expect(ok.x3dDiagnostics.filter {
        if case .unregisteredShader = $0.kind { return true }
        return false
    }.isEmpty)
}

@Test @XUIActor func recipeTiltCardExposesInteractivePlaneHits() async throws {
    let layout = await renderLayout(X3DView { TiltCardRecipe(tilt: 0.15) })
    #expect(layout.regions.isEmpty)
    #expect(layout.x3dPlanes.count == 1)
    let plane = try #require(layout.x3dPlanes.first)
    #expect(plane.regions.count == 1)
    #expect(plane.planeSize == Size(width: 40, height: 20))
    #expect(layout.hit(Point(x: 50, y: 25), as: String.self) == "card")
    #expect(layout.hit(Point(x: 2, y: 2), as: String.self) == nil)
}

@Test @XUIActor func recipeTiltCardPreciseHitSurvivesHeavyTilt() async throws {
    let layout = await renderLayout(X3DView { TiltCardRecipe(tilt: 0.7) })
    let plane = try #require(layout.x3dPlanes.first)
    // Centre of the view still maps onto the panel.
    #expect(layout.hit(Point(x: 50, y: 25), as: String.self) == "card")
    // Well outside the projected AABB must miss.
    let bounds = try #require(X3DPlaneHit.screenBounds(
        viewSize: SIMD2(Float(plane.hostRect.width), Float(plane.hostRect.height)),
        planeSize: SIMD2(Float(plane.planeSize.width), Float(plane.planeSize.height)),
        camera: plane.camera,
        model: plane.model
    ))
    let outside = Point(x: Double(bounds.min.x) - 20, y: Double(bounds.min.y) - 20)
    #expect(layout.hit(outside, as: String.self) == nil)
}

@Test @XUIActor func interactivePlanePromotesControlsToScreenSpace() async throws {
    let layout = await renderLayout(
        X3DView {
            Camera(position: SIMD3(0, 0, 3), acceptsInput: true) {
                Color.green.frame(width: 40, height: 20)
                    .control(XControl(id: "panel", label: "Panel"))
            }
        }
    )
    #expect(layout.x3dPlanes.count == 1)
    #expect(layout.controls.count == 1)
    let control = try #require(layout.controls.first)
    #expect(control.control.id == "panel")
    // Promoted into the X3DView's screen space (not stuck at local 0,0).
    #expect(control.rect.midX > 20)
    #expect(control.rect.midY > 5)
}

@Test @XUIActor func recipeTiltCardLowersRotatedPlane() async throws {
    let scene = await render(X3DView { TiltCardRecipe(tilt: 0.2) })
    guard case .x3d(let command) = try #require(scene.commands.first),
          case .render(let pass) = try #require(command.graph.passes.first),
          case .plane(let size, _, let camera, let model) = try #require(pass.items.first) else {
        Issue.record("Expected a tilted plane")
        return
    }
    #expect(size == RenderSize(width: 40, height: 20))
    #expect(camera.position == SIMD3(0, 0, 3))
    #expect(model != .identity)
}
