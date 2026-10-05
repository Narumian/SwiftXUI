import Testing
import XShader

private func project(_ m: [Float], _ p: SIMD3<Float>) -> SIMD3<Float> {
    var clip = SIMD4<Float>(repeating: 0)
    for row in 0..<4 {
        clip[row] = m[row] * p.x + m[4 + row] * p.y + m[8 + row] * p.z + m[12 + row]
    }
    return SIMD3(clip.x, clip.y, clip.z) / clip.w
}

@Test func cameraProjectsTargetToTheCentreWithinClipDepth() {
    let camera = X3DCamera(position: SIMD3(0, 0, 5), near: 0.1, far: 50)
    let ndc = project(camera.viewProjection(aspect: 16.0 / 9.0, time: 0), .zero)
    #expect(abs(ndc.x) < 1e-5)
    #expect(abs(ndc.y) < 1e-5)
    #expect(ndc.z > 0 && ndc.z < 1)
}

@Test func nearerPointsHaveSmallerDepthAndRightIsPositiveX() {
    let camera = X3DCamera(position: SIMD3(0, 0, 5))
    let m = camera.viewProjection(aspect: 1, time: 0)
    #expect(project(m, SIMD3(0, 0, 1)).z < project(m, SIMD3(0, 0, -1)).z)
    #expect(project(m, SIMD3(1, 0, 0)).x > 0)
    #expect(project(m, SIMD3(0, 1, 0)).y > 0)
}

@Test func orbitTurnsTheEyeAroundTheTargetAtConstantDistance() {
    let camera = X3DCamera(position: SIMD3(0, 1, 4), orbit: .pi / 2)
    let eye = camera.eye(at: 1)
    #expect(abs(eye.x - 4) < 1e-4)
    #expect(abs(eye.y - 1) < 1e-4)
    #expect(abs(eye.z) < 1e-4)
}
