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

@Test func planeProjectRoundTripsCentre() throws {
    let camera = X3DCamera(position: SIMD3(0, 0, 3))
    let screen = try #require(X3DPlaneHit.project(
        local: SIMD2(20, 10),
        viewSize: SIMD2(100, 50),
        planeSize: SIMD2(40, 20),
        camera: camera,
        model: .identity
    ))
    #expect(abs(screen.x - 50) < 0.5)
    #expect(abs(screen.y - 25) < 0.5)
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

@Test func planeHitTracksTranslatedAxisAlignedPanel() throws {
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

@Test func planeHitTracksHeavilyTiltedPanel() throws {
    let camera = X3DCamera(position: SIMD3(0, 0, 3))
    let model =
        X3DTransform.rotation(axis: SIMD3(0, 1, 0), angle: 0.7)
        * X3DTransform.rotation(axis: SIMD3(1, 0, 0), angle: 0.25)
    let centre = try #require(X3DPlaneHit.hit(
        screen: SIMD2(50, 25),
        viewSize: SIMD2(100, 50),
        planeSize: SIMD2(40, 20),
        camera: camera,
        model: model
    ))
    #expect(abs(centre.x - 20) < 1.0)
    #expect(abs(centre.y - 10) < 1.0)

    // Project a local corner, then hit it back — round-trip through tilt.
    let localCorner = SIMD2<Float>(5, 5)
    let screen = try #require(X3DPlaneHit.project(
        local: localCorner,
        viewSize: SIMD2(100, 50),
        planeSize: SIMD2(40, 20),
        camera: camera,
        model: model
    ))
    let back = try #require(X3DPlaneHit.hit(
        screen: screen,
        viewSize: SIMD2(100, 50),
        planeSize: SIMD2(40, 20),
        camera: camera,
        model: model
    ))
    #expect(abs(back.x - localCorner.x) < 0.75)
    #expect(abs(back.y - localCorner.y) < 0.75)

    // Far outside the projected AABB must miss (precise ray-plane, not AABB).
    let bounds = try #require(X3DPlaneHit.screenBounds(
        viewSize: SIMD2(100, 50),
        planeSize: SIMD2(40, 20),
        camera: camera,
        model: model
    ))
    #expect(!X3DPlaneHit.contains(
        screen: SIMD2(bounds.min.x - 20, bounds.min.y - 20),
        viewSize: SIMD2(100, 50),
        planeSize: SIMD2(40, 20),
        camera: camera,
        model: model
    ))

    // At extreme combined tilt the AABB is larger than the projected quad —
    // at least one AABB corner must miss the precise hit.
    let extreme =
        X3DTransform.rotation(axis: SIMD3(0, 1, 0), angle: 1.1)
        * X3DTransform.rotation(axis: SIMD3(1, 0, 0), angle: 0.6)
    let extremeBounds = try #require(X3DPlaneHit.screenBounds(
        viewSize: SIMD2(100, 50),
        planeSize: SIMD2(40, 20),
        camera: camera,
        model: extreme
    ))
    let aabbCorners = [
        SIMD2(extremeBounds.min.x, extremeBounds.min.y),
        SIMD2(extremeBounds.max.x, extremeBounds.min.y),
        SIMD2(extremeBounds.max.x, extremeBounds.max.y),
        SIMD2(extremeBounds.min.x, extremeBounds.max.y),
    ]
    let misses = aabbCorners.filter {
        !X3DPlaneHit.contains(
            screen: $0, viewSize: SIMD2(100, 50), planeSize: SIMD2(40, 20),
            camera: camera, model: extreme
        )
    }
    #expect(!misses.isEmpty)
    // Centre still hits under the same extreme tilt.
    #expect(X3DPlaneHit.contains(
        screen: SIMD2(50, 25),
        viewSize: SIMD2(100, 50),
        planeSize: SIMD2(40, 20),
        camera: camera,
        model: extreme
    ))
}

@Test func screenBoundsContainTheProjectedCentre() throws {
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
