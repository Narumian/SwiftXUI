import Testing
import XShader

@Test func planeHitMapsViewCentreToPlaneCentre() throws {
    let camera = X3DCamera(position: SIMD3(0, 0, 3))
    let local = X3DPlaneHit.hit(
        screen: SIMD2(50, 25),
        viewSize: SIMD2(100, 50),
        planeSize: SIMD2(40, 20),
        camera: camera,
        model: .identity
    )
    let point = try #require(local)
    #expect(abs(point.x - 20) < 0.5)
    #expect(abs(point.y - 10) < 0.5)
}

@Test func planeHitMissesOutsideThePanel() {
    let camera = X3DCamera(position: SIMD3(0, 0, 3))
    let miss = X3DPlaneHit.hit(
        screen: SIMD2(0, 0),
        viewSize: SIMD2(100, 50),
        planeSize: SIMD2(40, 20),
        camera: camera,
        model: .identity
    )
    #expect(miss == nil)
}

@Test func planeHitTracksTranslatedAxisAlignedPanel() {
    let camera = X3DCamera(position: SIMD3(0, 0, 3))
    let model = X3DTransform.translation(SIMD3(0.2, 0, 0))
    let hit = X3DPlaneHit.hit(
        screen: SIMD2(50, 25),
        viewSize: SIMD2(100, 50),
        planeSize: SIMD2(40, 20),
        camera: camera,
        model: model
    )
    // Centre ray now lands left of the panel centre in local space.
    let point = try #require(hit)
    #expect(point.x < 20)
}

@Test func screenBoundsContainTheProjectedCentre() {
    let camera = X3DCamera(position: SIMD3(0, 0, 3))
    let bounds = try #require(X3DPlaneHit.screenBounds(
        viewSize: SIMD2(100, 50),
        planeSize: SIMD2(40, 20),
        camera: camera,
        model: .identity
    ))
    #expect(bounds.min.x < 50 && bounds.max.x > 50)
    #expect(bounds.min.y < 25 && bounds.max.y > 25)
}
