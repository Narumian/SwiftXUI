import Testing
import XShader

private func apply(_ t: X3DTransform, _ p: SIMD3<Float>) -> SIMD3<Float> {
    let m = t.matrix
    return SIMD3(
        m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
        m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
        m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14]
    )
}

@Test func transformsComposeRightToLeft() {
    let t = X3DTransform.translation(SIMD3(1, 0, 0)) * .scale(2)
    let p = apply(t, SIMD3(1, 1, 1))
    #expect(p == SIMD3(3, 2, 2))
}

@Test func rotationTurnsXTowardYAboutZ() {
    let p = apply(.rotation(axis: SIMD3(0, 0, 1), angle: .pi / 2), SIMD3(1, 0, 0))
    #expect(abs(p.x) < 1e-5 && abs(p.y - 1) < 1e-5)
}

@Test func icosphereIsAUnitTriangleList() {
    let mesh = X3DMesh.icosphere(subdivisions: 1)
    #expect(mesh.count == 80 * 3 * X3DMesh.floatsPerVertex)
    let first = SIMD3(mesh[0], mesh[1], mesh[2])
    #expect(abs((first * first).sum() - 1) < 1e-5)
}
