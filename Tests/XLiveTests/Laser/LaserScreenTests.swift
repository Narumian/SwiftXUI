import Foundation
import simd
import XCTest
@testable import XLive

/// The identity projection: a vertex's x and y are its scanner coordinates, so the
/// tests can place a path inside and outside the square directly.
private func settings(_ screen: LaserScreenMode, dwell: Int = 0, blank: Int = 0) -> LaserProjection {
    LaserProjection(projection: matrix_identity_double4x4, near: -10, far: 10, dwell: dwell, blank: blank, screen: screen)
}
private func path(_ xs: [Double], y: Double = 0, id: UInt32 = 1) -> [TestShape] {
    [TestShape(id: LaserShapeID(id), vertices: xs.map { LaserVertex(x: $0, y: y) })]
}
private func points(_ shapes: [Laser2DShape]) -> [LaserPoint] { shapes.flatMap(\.points) }
private func path2(_ vertices: [LaserVertex]) -> [TestShape] { [TestShape(id: 1, vertices: vertices)] }
private func modes(_ shapes: [Laser2DShape]) -> [LaserPointMode] { points(shapes).map(\.mode) }

final class LaserScreenTests: XCTestCase {
    /// 0 and 0.5 are inside; 2 and 3 are outside; -0.5 comes back in.
    private let route: [Double] = [0, 0.5, 2, 3, -0.5]

    func testClampKeepsEverySampleAndSquashesThemOntoTheEdge() {
        var projector = LaserProjector(settings(.clamp))
        let out = projector.project(path(route))
        XCTAssertEqual(points(out).map(\.xy.x), [0, 0.5, 1, 1, -0.5])
        XCTAssertTrue(points(out).allSatisfy { $0.mode == .normal && $0.rgb != .zero })
    }

    func testCutLeavesAtTheEdgeWithPaddingAndComesBackWithPaddingAndTheVertex() {
        var projector = LaserProjector(settings(.cut, dwell: 2, blank: 3))
        let out = projector.project(path(route))
        XCTAssertEqual(modes(out), [.normal, .normal,                                  // inside
                                    .normal, .dwell, .dwell, .blank,                    // leaves: edge, 2 dwell, 1 blank
                                    .blank, .blank, .blank, .dwell, .dwell, .normal,    // returns: 3 blank, 2 dwell, edge
                                    .normal])                                           // and the vertex itself
        XCTAssertEqual(points(out)[2].xy.x, 1)
        XCTAssertEqual(points(out)[11].xy.x, 1)
        XCTAssertEqual(points(out)[12].xy.x, -0.5)
    }

    func testBlankingKeepsTheScannerOnThePathAndAddsNoPadding() {
        var projector = LaserProjector(settings(.blanking, dwell: 2, blank: 3))
        let out = projector.project(path(route))
        XCTAssertEqual(modes(out), [.normal, .normal,
                                    .normal, .blank, .normal, .normal,                  // edge, one dark sample, then held on the edge twice
                                    .blank, .normal, .normal])                          // back: dark at the edge, lit edge, the vertex
        XCTAssertEqual(points(out).map(\.xy.x), [0, 0.5, 1, 1, 1, 1, 1, 1, -0.5])
        XCTAssertFalse(points(out).contains { $0.mode == .dwell })
        XCTAssertEqual(points(out).map { $0.rgb == .zero }, [false, false, false, true, true, true, true, false, false])
    }

    func testBlankingWithPaddingAddsThePaddingAtEachCrossing() {
        var projector = LaserProjector(settings(.blankingWithPadding, dwell: 2, blank: 3))
        let out = projector.project(path(route))
        XCTAssertEqual(modes(out), [.normal, .normal,
                                    .normal, .dwell, .dwell, .blank, .normal,           // leaves, then the outside vertex held dark
                                    .normal,                                            // the next outside vertex
                                    .blank, .blank, .blank, .dwell, .dwell, .normal,    // returns
                                    .normal])
        XCTAssertEqual(points(out).count, 15)
    }

    func testBlankingDoesNotChangeHowManySamplesAPathOffTheScreenTakes() {
        // 40 vertices that all lie off the screen: the scanner still takes 40 samples.
        var blanking = LaserProjector(settings(.blanking))
        XCTAssertEqual(blanking.project(path((0..<40).map { 2 + Double($0) * 0.1 })).flatMap(\.points).count, 40)
        var cut = LaserProjector(settings(.cut))
        XCTAssertEqual(cut.project(path((0..<40).map { 2 + Double($0) * 0.1 })).flatMap(\.points).count, 0)
    }

    func testTheEdgePointIsOnTheStraightLine() {
        var projector = LaserProjector(settings(.cut))
        let out = projector.project(path2([LaserVertex(x: 0, y: 0), LaserVertex(x: 2, y: 4)]))
        XCTAssertEqual(points(out).count, 2)                        // the first vertex, then the edge point
        XCTAssertEqual(points(out)[1].xy.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(points(out)[1].xy.y, 1, accuracy: 1e-6)
    }

    func testAPathThatStartsOffTheScreen() {
        var blanking = LaserProjector(settings(.blanking))
        XCTAssertEqual(points(blanking.project(path([5]))).map(\.rgb), [.zero])
        var cut = LaserProjector(settings(.cut))
        XCTAssertTrue(cut.project(path([5])).isEmpty)
    }

    func testEachShapeStartsFreshSoALeavingShapeDoesNotPadTheNext() {
        var projector = LaserProjector(settings(.cut, dwell: 0, blank: 1))
        let frame = path([0.5, 2], id: 1) + path([0.2], id: 2)
        let out = projector.project(frame)
        XCTAssertEqual(out.map(\.id), [1, 2])
        XCTAssertEqual(modes([out[0]]), [.normal, .normal, .blank])   // inside, the edge, one dark sample
        XCTAssertEqual(modes([out[1]]), [.normal])                    // a new shape: no entry padding
    }

    func testBlankingThenSamplingDrawsNothingLitOffTheScreen() {
        var projector = LaserProjector(settings(.blanking))
        var resampler = LaserResampler(maximumStep: 0.25)
        let out = resampler.process(projector.project(path([0, 0.5, 2, 3, -0.5])))
        // A lit point is only ever inside the square, and the move out and back is dark.
        for p in points(out) where p.rgb != .zero { XCTAssertLessThanOrEqual(abs(p.xy.x), 1) }
        let darkRun = points(out).drop { $0.rgb != .zero || $0.xy.x < 0.9 }.prefix { $0.rgb == .zero }
        XCTAssertGreaterThan(darkRun.count, 0)
    }
}
