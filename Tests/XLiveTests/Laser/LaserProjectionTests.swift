import Foundation
import simd
import XCTest
@testable import XLive

/// Camera 2 in front of the shapes: camera z = shape z + 2.
private func settings(dwell: Int = 0, blank: Int = 0) -> LaserProjection {
    var camera = matrix_identity_double4x4
    camera.columns.3 = SIMD4(0, 0, 2, 1)
    return LaserProjection(camera: camera,
                           projection: LaserProjection.perspective(fovxDegrees: 90, near: 0.1, far: 50),
                           near: 0.1, far: 50, dwell: dwell, blank: blank)
}

private func vertex(_ x: Double, _ z: Double = 0) -> LaserVertex {
    LaserVertex(x: Float(x), y: 0, z: Float(z), rgba: SIMD4(1, 0.5, 0.25, 1))
}
private func shape(_ id: UInt32, _ vertices: [LaserVertex]) -> TestShape { TestShape(id: LaserShapeID(id), vertices: vertices) }
private func flat(_ shapes: [Laser2DShape]) -> [LaserPoint] { shapes.flatMap(\.points) }

final class LaserProjectionTests: XCTestCase {
    func testAVertexInsideTheViewProjectsWithMirroredXAndColourTimesAlpha() {
        var projector = LaserProjector(settings())
        let out = projector.project([shape(3, [LaserVertex(x: 0.5, y: 0.25, rgba: SIMD4(1, 0.5, 0.25, 0.5))])])
        XCTAssertEqual(out.map(\.id), [3])
        XCTAssertEqual(flat(out).count, 1)
        let p = flat(out)[0]
        XCTAssertEqual(p.xy.x, -0.25, accuracy: 1e-6)    // x * -1 / camera z 2
        XCTAssertEqual(p.xy.y, 0.125, accuracy: 1e-6)
        XCTAssertEqual(p.rgb.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.rgb.z, 0.125, accuracy: 1e-6)
        XCTAssertEqual(p.mode, .normal)
    }

    func testOffScreenCoordinatesAreClampedToTheScanner() {
        var projector = LaserProjector(settings())
        XCTAssertEqual(flat(projector.project([shape(1, [vertex(40)])])).first?.xy.x, -1)
    }

    func testAShapeWhollyOutsideTheViewIsDropped() {
        var projector = LaserProjector(settings())
        let out = projector.project([shape(1, [vertex(0, 100), vertex(1, 120), vertex(0, -9)]), shape(2, [vertex(0.1)])])
        XCTAssertEqual(out.map(\.id), [2])
    }

    func testLeavingTheViewEndsOnThePlaneWithDwellThenBlank() {
        var projector = LaserProjector(settings(dwell: 2, blank: 3))
        let out = flat(projector.project([shape(1, [vertex(0.5, 0), vertex(0.5, 100)])]))
        // the first vertex, the cut point, 2 dwell, 3 blank
        XCTAssertEqual(out.map(\.mode), [.normal, .normal, .dwell, .dwell, .blank, .blank, .blank])
        // cut at camera z = far (50): x = -0.5 / 50 after the mirrored divide
        XCTAssertEqual(out[1].xy.x, -0.01, accuracy: 1e-4)
        XCTAssertEqual(out[2].xy, out[1].xy)
        XCTAssertEqual(out[2].rgb, out[1].rgb)
        XCTAssertEqual(out[4].rgb, .zero)
    }

    func testComingBackIntoTheViewStartsWithBlankThenDwellThenTheVertex() {
        var projector = LaserProjector(settings(dwell: 2, blank: 3))
        // inside, far outside, then back inside
        let out = flat(projector.project([shape(1, [vertex(0, 0), vertex(0, 100), vertex(0, 10)])]))
        XCTAssertEqual(out.map(\.mode),
                       [.normal,                                        // start
                        .normal, .dwell, .dwell, .blank, .blank, .blank, // leaving
                        .blank, .blank, .blank, .dwell, .dwell, .normal, // coming back: cut point
                        .normal])                                        // the vertex itself
    }

    func testAPathIsNotDrawnAcrossAShapeBoundary() {
        var projector = LaserProjector(settings(dwell: 1, blank: 1))
        let out = projector.project([shape(1, [vertex(0, 0), vertex(0, 100)]), shape(2, [vertex(0, 5), vertex(0, 6)])])
        // shape 1: vertex + cut + dwell + blank = 4; shape 2 starts fresh, so no entry at its first vertex: 2
        XCTAssertEqual(out.map(\.id), [1, 2])
        XCTAssertEqual(out.map(\.points.count), [4, 2])
    }

    func testEveryFrameStartsFreshSoNothingCarriesFromTheLastOne() {
        var projector = LaserProjector(settings(dwell: 0, blank: 1))
        _ = projector.project([shape(1, [vertex(0, 0), vertex(0, 100)])])         // ended outside the view
        let again = projector.project([shape(1, [vertex(0, 0)])])
        XCTAssertEqual(flat(again).map(\.mode), [.normal])                          // no entry padding for a new frame
    }

    // MARK: Shape model matrix and tint

    private func placed(_ attributes: [Laser3DShapeAttributes], _ vertices: [[LaserVertex]]) -> Laser3DBuffer {
        var buffer = Laser3DBuffer()
        for (index, shape) in vertices.enumerated() {
            try! buffer.beginShape(id: LaserShapeID(UInt32(index + 1)), attributes: attributes[index])
            for vertex in shape { try! buffer.appendVertex(vertex) }
        }
        return buffer
    }

    private func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(x, y, z, 1)
        return m
    }

    func testTheModelMatrixMovesTheShapeBeforeTheCamera() {
        var projector = LaserProjector(settings())
        let moved = placed([Laser3DShapeAttributes(matrix: translation(0.5, 0.25, 0))], [[LaserVertex(x: 0, y: 0)]])
        let p = flat(projector.project(moved))[0]
        XCTAssertEqual(p.xy.x, -0.25, accuracy: 1e-6)   // same as a vertex at x = 0.5
        XCTAssertEqual(p.xy.y, 0.125, accuracy: 1e-6)
    }

    func testTheModelMatrixOfOneShapeDoesNotLeakIntoTheNext() {
        var projector = LaserProjector(settings())
        let buffer = placed([Laser3DShapeAttributes(matrix: translation(0.5, 0, 0)), .identity],
                            [[LaserVertex(x: 0, y: 0)], [LaserVertex(x: 0, y: 0)]])
        let out = projector.project(buffer)
        XCTAssertEqual(out.map(\.id), [1, 2])
        XCTAssertEqual(out[0].points[0].xy.x, -0.25, accuracy: 1e-6)
        XCTAssertEqual(out[1].points[0].xy.x, 0, accuracy: 1e-6)
    }

    func testTheTintMultipliesTheColourBeforeAlphaAndLimit() {
        var projector = LaserProjector(settings())
        let tinted = placed([Laser3DShapeAttributes(tint: SIMD4(0.5, 1, 0, 0.5))],
                            [[LaserVertex(x: 0, y: 0, rgba: SIMD4(1, 0.5, 1, 1))]])
        let p = flat(projector.project(tinted))[0]
        XCTAssertEqual(p.rgb.x, 0.25, accuracy: 1e-6)    // 1 * 0.5 * alpha(1 * 0.5)
        XCTAssertEqual(p.rgb.y, 0.25, accuracy: 1e-6)
        XCTAssertEqual(p.rgb.z, 0, accuracy: 1e-6)
    }

    func testTheModelMatrixTakesTheShapeThroughNearAndFarCuts() {
        var projector = LaserProjector(settings(dwell: 1, blank: 1))
        // Pushed 100 away along z, the shape is wholly out of view and dropped.
        let far = placed([Laser3DShapeAttributes(matrix: translation(0, 0, 100))], [[vertex(0.1), vertex(0.2)]])
        XCTAssertTrue(projector.project(far).isEmpty)
        // One vertex stays in view, so the path is cut on the plane like an untransformed one.
        let half = placed([Laser3DShapeAttributes(matrix: translation(0, 0, 50))], [[vertex(0.5, -49), vertex(0.5, 100)]])
        XCTAssertEqual(flat(projector.project(half)).map(\.mode), [.normal, .normal, .dwell, .blank])
    }

    func testProjectingAShapeEqualsProjectingTheBufferWithItBakedIn() {
        let rotate = simd_float4x4(rows: [SIMD4(0.8, -0.6, 0, 0.1), SIMD4(0.6, 0.8, 0, -0.2), SIMD4(0, 0, 1, 0.3), SIMD4(0, 0, 0, 1)])
        let buffer = placed([Laser3DShapeAttributes(matrix: rotate, tint: SIMD4(0.9, 0.8, 0.7, 0.6)), .identity],
                            [[vertex(0.3), vertex(-0.4, 0.5), vertex(0.1, -0.2)], [vertex(0.2)]])
        var lazy = LaserProjector(settings(dwell: 2, blank: 2)), eager = LaserProjector(settings(dwell: 2, blank: 2))
        let a = lazy.project(buffer), b = eager.project(buffer.baked())
        XCTAssertEqual(a.map(\.id), b.map(\.id))
        let (pa, pb) = (flat(a), flat(b))
        XCTAssertEqual(pa.count, pb.count)
        for (x, y) in zip(pa, pb) {
            XCTAssertEqual(x.xy.x, y.xy.x, accuracy: 1e-5); XCTAssertEqual(x.xy.y, y.xy.y, accuracy: 1e-5)
            XCTAssertEqual(x.rgb.x, y.rgb.x, accuracy: 1e-5); XCTAssertEqual(x.rgb.y, y.rgb.y, accuracy: 1e-5)
            XCTAssertEqual(x.mode, y.mode)
        }
    }
}
