import Foundation
import simd
import XCTest
@testable import XLive

private func vertex(_ x: Double, _ z: Double = 0) -> LaserVertex { LaserVertex(x: x, y: 0, z: z) }

private struct Script<Element: Sendable>: LaserStream {
    var format: LaserStreamFormat
    var chunks: [LaserChunk<Element>]
    mutating func read(wanting count: Int) -> LaserChunk<Element> { chunks.isEmpty ? LaserChunk() : chunks.removeFirst() }
}

final class LaserReviewTests: XCTestCase {
    /// Runs that stick out of the chunk must not trap a real-time pump.
    func testMalformedRunsAreClampedInsteadOfTrapping() {
        var stage = LaserDwellBlank(dwell: 1, blank: 1)
        let chunk = LaserChunk(elements: [vertex(0.1), vertex(0.2)],
                               runs: [LaserRun(id: 1, range: 0..<2), LaserRun(id: 2, range: 1..<9), LaserRun(id: 3, range: 7..<9)],
                               frameEnds: [2, 40])
        let out = stage.process(chunk)
        XCTAssertEqual(out.count, 6)
        XCTAssertEqual(out.runs, [LaserRun(id: 1, range: 0..<6)])
    }

    /// A stage that drops a whole chunk must not make the reader think the stream is dry.
    func testAStagedStreamSkipsChunksThatProjectToNothing() {
        var camera = matrix_identity_double4x4
        camera.columns.3 = SIMD4(0, 0, 2, 1)
        let projection = LaserProjection(camera: camera,
                                         projection: LaserProjection.perspective(fovxDegrees: 90, near: 0.1, far: 50))
        let hidden = LaserChunk(elements: [vertex(0, 100), vertex(0, 120)], shape: 1)
        let shown = LaserChunk(elements: [vertex(0.1), vertex(0.2)], shape: 2)
        let source = Script(format: LaserStreamFormat(domain: .shapes), chunks: [hidden, hidden, shown])
        var stream = LaserStagedStream(source, stage: LaserProjector(projection), format: LaserStreamFormat(domain: .scanner, rate: 30000))
        let out = stream.read(wanting: 10)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.runs.first?.id, 2)
    }

    func testAStagedStreamStillReportsNothingWhenTheUpstreamIsDry() {
        var stream = LaserStagedStream(Script<LaserVertex>(format: LaserStreamFormat(domain: .shapes), chunks: []),
                                       stage: LaserDwellBlank(dwell: 1, blank: 1), format: LaserStreamFormat(domain: .shapes))
        XCTAssertTrue(stream.read(wanting: 10).isEmpty)
    }
}
