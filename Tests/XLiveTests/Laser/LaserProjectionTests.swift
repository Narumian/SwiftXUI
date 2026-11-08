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
    LaserVertex(x: x, y: 0, z: z, rgba: SIMD4(1, 0.5, 0.25, 1))
}

final class LaserProjectionTests: XCTestCase {
    func testAVertexInsideTheViewProjectsWithMirroredXAndColourTimesAlpha() {
        var projector = LaserProjector(settings())
        let out = projector.project(LaserChunk(elements: [LaserVertex(x: 0.5, y: 0.25, rgba: SIMD4(1, 0.5, 0.25, 0.5))], shape: 3))
        XCTAssertEqual(out.count, 1)
        let p = out.elements[0]
        XCTAssertEqual(p.xy.x, -0.25, accuracy: 1e-6)    // x * -1 / camera z 2
        XCTAssertEqual(p.xy.y, 0.125, accuracy: 1e-6)
        XCTAssertEqual(p.rgb.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.rgb.z, 0.125, accuracy: 1e-6)
        XCTAssertEqual(p.mode, .normal)
        XCTAssertEqual(out.runs, [LaserRun(id: 3, range: 0..<1)])
    }

    func testOffScreenCoordinatesAreClampedToTheScanner() {
        var projector = LaserProjector(settings())
        let out = projector.project(LaserChunk(elements: [vertex(40)], shape: 1))
        XCTAssertEqual(out.elements.first?.xy.x, -1)
    }

    func testAPathWhollyOutsideTheViewDrawsNothing() {
        var projector = LaserProjector(settings())
        let out = projector.project(LaserChunk(elements: [vertex(0, 100), vertex(1, 120), vertex(0, -9)], shape: 1))
        XCTAssertTrue(out.isEmpty)
        XCTAssertTrue(out.runs.isEmpty)
    }

    func testLeavingTheViewEndsOnThePlaneWithDwellThenBlank() {
        var projector = LaserProjector(settings(dwell: 2, blank: 3))
        let out = projector.project(LaserChunk(elements: [vertex(0.5, 0), vertex(0.5, 100)], shape: 1))
        // the first vertex, the cut point, 2 dwell, 3 blank
        XCTAssertEqual(out.elements.map(\.mode), [.normal, .normal, .dwell, .dwell, .blank, .blank, .blank])
        // cut at camera z = far (50): x = -0.5 / 50 after the mirrored divide
        XCTAssertEqual(out.elements[1].xy.x, -0.01, accuracy: 1e-4)
        XCTAssertEqual(out.elements[2].xy, out.elements[1].xy)
        XCTAssertEqual(out.elements[2].rgb, out.elements[1].rgb)
        XCTAssertEqual(out.elements[4].rgb, .zero)
        XCTAssertEqual(out.runs, [LaserRun(id: 1, range: 0..<7)])
    }

    func testComingBackIntoTheViewStartsWithBlankThenDwellThenTheVertex() {
        var projector = LaserProjector(settings(dwell: 2, blank: 3))
        // inside, far outside, then back inside
        let out = projector.project(LaserChunk(elements: [vertex(0, 0), vertex(0, 100), vertex(0, 10)], shape: 1))
        XCTAssertEqual(out.elements.map(\.mode),
                       [.normal,                                        // start
                        .normal, .dwell, .dwell, .blank, .blank, .blank, // leaving
                        .blank, .blank, .blank, .dwell, .dwell, .normal, // coming back: cut point
                        .normal])                                        // the vertex itself
    }

    func testAPathIsNotDrawnAcrossAShapeBoundary() {
        var projector = LaserProjector(settings(dwell: 1, blank: 1))
        let chunk = LaserChunk(elements: [vertex(0, 0), vertex(0, 100), vertex(0, 5), vertex(0, 6)],
                               runs: [LaserRun(id: 1, range: 0..<2), LaserRun(id: 2, range: 2..<4)],
                               frameEnds: [4])
        let out = projector.project(chunk)
        // shape 1: vertex + cut + dwell + blank = 4; shape 2 starts fresh, so no entry at its first vertex: 2
        XCTAssertEqual(out.count, 6)
        XCTAssertEqual(out.runs, [LaserRun(id: 1, range: 0..<4), LaserRun(id: 2, range: 4..<6)])
        XCTAssertEqual(out.frameEnds, [6])
    }

    func testStateCarriesAcrossChunksOfOneShape() {
        var projector = LaserProjector(settings(dwell: 0, blank: 1))
        let first = projector.project(LaserChunk(elements: [vertex(0, 0)], shape: 1))
        XCTAssertEqual(first.count, 1)
        let second = projector.project(LaserChunk(elements: [vertex(0, 100)], shape: 1))   // same shape continues
        XCTAssertEqual(second.elements.map(\.mode), [.normal, .blank])                       // the cut is still found
        let third = projector.project(LaserChunk(elements: [vertex(0, 0)], shape: 2))      // a new shape: no entry
        XCTAssertEqual(third.elements.map(\.mode), [.normal])
    }

    func testFrameEndsLandAfterTheirLastProjectedSample() {
        var projector = LaserProjector(settings())
        let out = projector.project(LaserChunk(elements: [vertex(0, 0), vertex(0, 100), vertex(0, 100), vertex(0, 0)],
                                               runs: [LaserRun(id: 1, range: 0..<4)], frameEnds: [3, 4]))
        // vertex, cut | (dropped) | restart: vertex
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.frameEnds, [2, 3])
    }

    func testProjectedStreamReadsAFrameLooperAndIsAnOutputStream() {
        let looper = LaserFrameLooper<LaserVertex>(format: LaserStreamFormat(domain: .shapes))
        looper.submit(LaserChunk(elements: [vertex(0.1), vertex(0.2), vertex(0.3)], shape: 9))
        var reader = LaserReader(LaserProjectedStream(looper, projection: settings(), rate: 30000))
        XCTAssertEqual(reader.format, LaserStreamFormat(domain: .scanner, rate: 30000))
        let block = reader.take(7)
        XCTAssertEqual(block.count, 7)
        XCTAssertEqual(block.frameEnds, [3, 6])
        XCTAssertEqual(block.runs, [LaserRun(id: 9, range: 0..<7)])
    }
}
