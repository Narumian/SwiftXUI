import Foundation
import simd
import XCTest
@testable import XLive

private func vertex(_ x: Double, _ z: Double = 0) -> LaserVertex { LaserVertex(x: Float(x), y: 0, z: Float(z)) }

final class LaserReviewTests: XCTestCase {
    func testAChainReportsNothingWhenTheFrameIsOutOfView() {
        var camera = matrix_identity_double4x4
        camera.columns.3 = SIMD4(0, 0, 2, 1)
        let projection = LaserProjection(camera: camera, projection: LaserProjection.perspective(fovxDegrees: 90, near: 0.1, far: 50))
        let box = FixedFrame([TestShape(id: 1, vertices: [vertex(0, 100), vertex(0, 120)])])
        var chain = LaserScannerChain(box, projection: projection, live: LaserLive(LaserScannerSettings()))
        XCTAssertTrue(chain.read().isEmpty)
        box.value = testBuffer([TestShape(id: 2, vertices: [vertex(0.1), vertex(0.2)])])
        XCTAssertEqual(chain.read().map(\.id), [2])
    }

    func testAChainReportsNothingWhenTheBufferIsEmpty() {
        let box = LaserLive(Laser3DBuffer())
        var chain = LaserScannerChain(box, projection: LaserProjection(projection: matrix_identity_double4x4, near: -10, far: 10), live: LaserLive(LaserScannerSettings()))
        XCTAssertTrue(chain.read().isEmpty)
    }

}
