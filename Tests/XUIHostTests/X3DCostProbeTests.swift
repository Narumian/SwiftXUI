import Testing
import XRender
import XShader
import XUI
@testable import XUIHost

private let particles = X3DResourceID(scope: 9, name: "particles")

private struct CostProbeProgram: X3DProgram {
    var body: some X3DProgram {
        Buffer("mesh", contents: [0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0])
        Draw("lit", vertices: 3).bind("mesh")
    }
}

/// Shared probe state is process-wide; keep these tests off the parallel pool.
@Suite(.serialized)
struct X3DSharedCostProbeTests {
    @Test func sceneBuilderAssembleFeedsSharedProbe() {
        let probe = X3DCostProbe.shared
        probe.reset()
        probe.isEnabled = true
        defer {
            probe.isEnabled = false
            probe.reset()
        }
        probe.beginFrame()
        var builder = SceneBuilder(size: RenderSize(width: 100, height: 50))
        builder.beginX3D(in: RenderRect(x: 0, y: 0, width: 100, height: 50))
        builder.emitX3D(.resource(.buffer(id: particles, byteCount: 64, contents: [1, 2, 3, 4])))
        builder.emitX3D(.beginPass(target: .output, load: .load, depth: false))
        builder.emitX3D(.draw(X3DDraw(
            shader: "flow", vertexEntry: "vs_main", fragmentEntry: "fs_main", vertexCount: 3
        )))
        builder.emitX3D(.endPass)
        builder.endX3D()
        probe.endFrame()
        #expect(probe.last.metrics.resources == 1)
        #expect(probe.last.metrics.draws == 1)
        #expect(probe.last.metrics.bufferBytes == 64)
    }

    @Test @XUIActor func costProbeRecordsWalkAndAssembleForX3DView() async {
        let probe = X3DCostProbe.shared
        probe.reset()
        probe.isEnabled = true
        defer {
            probe.isEnabled = false
            probe.reset()
        }

        let host = XUIHost(size: RenderSize(width: 100, height: 50))
        probe.beginFrame()
        _ = await host.render(X3DView { CostProbeProgram() })
        probe.endFrame()

        #expect(probe.last.metrics.resources == 1)
        #expect(probe.last.metrics.draws == 1)
        #expect(probe.last.nanoseconds(for: .walk) >= 0)
        #expect(probe.last.nanoseconds(for: .assemble) >= 0)
    }
}
