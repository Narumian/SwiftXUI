import Foundation
import simd
import XCTest
@testable import XLive

private func vertex(_ x: Double, _ z: Double = 0) -> LaserVertex { LaserVertex(x: x, y: 0, z: z) }

/// A source that answers with scripted frames, then nothing.
private struct Script: Laser3DStream {
    var frames: [[Laser3DShape]]
    mutating func read() -> [Laser3DShape] { frames.isEmpty ? [] : frames.removeFirst() }
}

final class LaserReviewTests: XCTestCase {
    private func chain(_ source: Script, projection: LaserProjection) -> LaserScannerChain<Script> {
        LaserScannerChain(source, projection: projection, live: LaserLive(LaserScannerSettings()), rate: 30000)
    }

    /// A frame that projects to nothing must not make the reader think the stream is dry.
    func testAChainSkipsFramesThatProjectToNothing() {
        var camera = matrix_identity_double4x4
        camera.columns.3 = SIMD4(0, 0, 2, 1)
        let projection = LaserProjection(camera: camera,
                                         projection: LaserProjection.perspective(fovxDegrees: 90, near: 0.1, far: 50))
        let hidden = [Laser3DShape(id: 1, vertices: [vertex(0, 100), vertex(0, 120)])]
        let shown = [Laser3DShape(id: 2, vertices: [vertex(0.1), vertex(0.2)])]
        var stream = chain(Script(frames: [hidden, hidden, shown]), projection: projection)
        let out = stream.read()
        XCTAssertEqual(out.map(\.id), [2])
        XCTAssertFalse(out[0].points.isEmpty)
    }

    func testAChainStillReportsNothingWhenTheUpstreamIsDry() {
        var stream = chain(Script(frames: []), projection: LaserProjection(projection: matrix_identity_double4x4, near: -10, far: 10))
        XCTAssertTrue(stream.read().isEmpty)
    }
}
