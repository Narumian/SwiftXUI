import Testing
import XShader
@testable import XRender

private let particles = X3DResourceID(scope: 7, name: "particles")
private let trail = X3DResourceID(scope: 7, name: "trail")

private func sampleGraph() -> X3DGraph {
    X3DGraph(
        resources: [
            .buffer(id: particles, byteCount: 64, contents: [1, 2, 3, 4]),
            .texture(id: trail, format: .rgba16Float, size: .target),
        ],
        passes: [
            .compute(X3DCompute(shader: "flow", entry: "step", threads: 4,
                                bindings: [X3DBinding(resource: particles, access: .readWrite)])),
            .render(X3DRenderPass(target: .texture(trail), load: .fade(0.1), items: [
                .draw(X3DDraw(shader: "flow", vertexEntry: "vs_main", fragmentEntry: "fs_main",
                              vertexCount: 6, instanceCount: 4)),
            ])),
            .render(X3DRenderPass(target: .output, load: .load, items: [
                .blit(trail, blend: .alpha),
                .plane(size: RenderSize(width: 40, height: 20), commands: [],
                       camera: X3DCamera(position: SIMD3(0, 0, 3)), model: .identity),
            ])),
        ]
    )
}

@Test func graphMetricsCountResourcesPassesAndPlanes() {
    let metrics = sampleGraph().metrics
    #expect(metrics.resources == 2)
    #expect(metrics.bufferBytes == 64)
    #expect(metrics.textures == 1)
    #expect(metrics.passes == 3)
    #expect(metrics.computes == 1)
    #expect(metrics.draws == 1)
    #expect(metrics.blits == 1)
    #expect(metrics.planes == 1)
    #expect(metrics.views == 0)
}

@Test func bufferUploadPolicyReusesEqualContentsOnly() {
    #expect(!X3DBufferUploadPolicy.needsReupload(
        existingByteCount: 16, existingContents: [1, 2, 3, 4],
        byteCount: 16, contents: [1, 2, 3, 4]
    ))
    #expect(X3DBufferUploadPolicy.needsReupload(
        existingByteCount: 16, existingContents: [1, 2, 3, 4],
        byteCount: 16, contents: [1, 2, 3, 5]
    ))
    #expect(X3DBufferUploadPolicy.needsReupload(
        existingByteCount: 16, existingContents: nil,
        byteCount: 16, contents: [0]
    ))
    #expect(!X3DBufferUploadPolicy.needsReupload(
        existingByteCount: 32, existingContents: nil,
        byteCount: 32, contents: nil
    ))
    #expect(X3DBufferUploadPolicy.needsReupload(
        existingByteCount: 16, existingContents: [1],
        resource: .buffer(id: particles, byteCount: 32, contents: [1])
    ))
}

@Test func planePolicyMatchesWorldScaleContract() {
    #expect(X3DPlanePolicy.pointsPerWorldUnit == 100)
    #expect(X3DPlanePolicy.worldSize(layoutPoints: SIMD2(40, 20)) == SIMD2(0.4, 0.2))
    #expect(X3DPlanePolicy.halfExtents(layoutPoints: SIMD2(40, 20)) == SIMD2(0.2, 0.1))
    #expect(X3DPlanePolicy.offscreenMatchesFramebuffer)
    #expect(X3DPlaneHit.pointsPerWorldUnit == X3DPlanePolicy.pointsPerWorldUnit)
}

@Test func costProbeRecordsAssembleMetricsWhenEnabled() {
    let probe = X3DCostProbe()
    probe.isEnabled = true
    probe.beginFrame()
    let started = probe.begin(.assemble)
    probe.end(.assemble, started: started)
    probe.record(metrics: sampleGraph().metrics)
    probe.record(churn: X3DResourceChurn(reused: 1, created: 2, bufferBytesUploaded: 64))
    probe.endFrame()
    #expect(probe.last.metrics.planes == 1)
    #expect(probe.last.churn.created == 2)
    #expect(probe.last.churn.bufferBytesUploaded == 64)
    #expect(probe.last.nanoseconds(for: .assemble) >= 0)
}

@Test func costProbeIsNoOpWhenDisabled() {
    let probe = X3DCostProbe()
    probe.isEnabled = false
    probe.beginFrame()
    let started = probe.begin(.walk)
    probe.end(.walk, started: started)
    probe.record(metrics: sampleGraph().metrics)
    probe.endFrame()
    #expect(probe.last.metrics.resources == 0)
    #expect(probe.last.nanoseconds.isEmpty)
}
