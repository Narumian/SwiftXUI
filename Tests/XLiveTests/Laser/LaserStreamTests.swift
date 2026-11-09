import Foundation
import simd
import XCTest
@testable import XLive

private func point(_ x: Float, lit: Bool = true) -> LaserPoint {
    try! LaserPoint(xy: SIMD2<Float>(x, 0), rgb: lit ? SIMD3<Float>(repeating: 0.5) : .zero, isBlanked: !lit)
}

/// A scanner stream that hands out scripted frame sizes, one shape each.
private struct ScriptedStream: Laser2DStream {
    var rate: UInt32? = 30000
    var sizes: [Int]
    var next = 0
    var reads = 0
    mutating func read() -> [Laser2DShape] {
        reads += 1
        guard !sizes.isEmpty else { return [] }
        let size = sizes.removeFirst()
        defer { next += size }
        return [Laser2DShape(id: 7, points: (next..<next + size).map { point(Float($0) / 1000) })]
    }
}

final class LaserStreamTests: XCTestCase {
    func testVertexIsHomogeneousAndKeepsItsModeThroughHelpers() {
        let v = LaserVertex(x: 1, y: 2, z: 3, rgba: SIMD4<Double>(1, 0.5, 0.25, 0.5))
        XCTAssertEqual(v.position, SIMD4<Double>(1, 2, 3, 1))
        XCTAssertEqual(v.mode, .normal)
        XCTAssertEqual(v.blanked().rgba, .zero)
        XCTAssertTrue(v.blanked().isBlanked)
        XCTAssertEqual(v.dwelling().mode, .dwell)
        XCTAssertEqual(v.dwelling().rgba, v.rgba)
        let moved = v.transformed(by: simd_double4x4(diagonal: SIMD4<Double>(2, 2, 2, 1)))
        XCTAssertEqual(moved.position, SIMD4<Double>(2, 4, 6, 1))
        XCTAssertEqual(v.scaledAlpha(0.5).rgba.w, 0.25)
    }

    func testPointModeIsSharedWithVerticesAndBlankingFollowsIt() throws {
        let lit = try LaserPoint(xy: SIMD2<Float>(0.5, 0), rgb: SIMD3<Float>(repeating: 0.5))
        XCTAssertEqual(lit.mode, .normal)
        XCTAssertFalse(lit.isBlanked)
        let held = lit.dwelling()
        XCTAssertEqual(held.mode, .dwell)
        XCTAssertEqual(held.rgb, lit.rgb)
        XCTAssertFalse(held.isBlanked)                  // a dwell is lit, it only holds still
        let dark = lit.blanked()
        XCTAssertTrue(dark.isBlanked)
        XCTAssertEqual(dark.rgb, .zero)
        XCTAssertEqual(try LaserPoint(xy: .zero, rgb: .zero, isBlanked: true).mode, .blank)
        XCTAssertEqual(LaserVertex.Mode.dwell, LaserPointMode.dwell)
        XCTAssertEqual(LaserPointMode.blank.rawValue, 2) // Legacy's raw values
    }

    func testReaderAsksAgainWhenShortAndStopsOnAnEmptyAnswer() {
        var reader = LaserReader(ScriptedStream(sizes: [3, 4]))
        let out = reader.take(10)
        XCTAssertEqual(out.count, 7)                       // the stream ran dry
        XCTAssertEqual(reader.stream.reads, 3)             // asked again for the shortfall, then an empty answer
        XCTAssertEqual(out.map(\.xy.x), (0..<7).map { Float($0) / 1000 })
    }

    func testReaderKeepsSurplusWhenTheStreamReturnsMoreThanWanted() {
        var reader = LaserReader(ScriptedStream(sizes: [10]))
        XCTAssertEqual(reader.take(4).count, 4)
        XCTAssertEqual(reader.surplus, 6)
        let rest = reader.take(6)
        XCTAssertEqual(rest.map(\.xy.x), (4..<10).map { Float($0) / 1000 })
        XCTAssertEqual(reader.stream.reads, 1)             // the surplus served the second take
    }

    func testReaderStopsAskingAStreamThatTrickles() {
        var reader = LaserReader(ScriptedStream(sizes: Array(repeating: 1, count: 100)))
        reader.maximumReadsPerTake = 5
        XCTAssertEqual(reader.take(50).count, 5)
    }

    func testTakeFilledDarkensAtTheLastPositionWhenStarved() {
        var reader = LaserReader(ScriptedStream(sizes: [3]))
        let out = reader.takeFilled(8)
        XCTAssertEqual(out.count, 8)
        XCTAssertTrue(out.prefix(3).allSatisfy { !$0.isBlanked })
        for p in out.dropFirst(3) { XCTAssertTrue(p.isBlanked && p.rgb == .zero && p.xy.x == 0.002) }
        var empty = LaserReader(ScriptedStream(sizes: []))
        XCTAssertTrue(empty.takeFilled(4).allSatisfy { $0.isBlanked && $0.xy == .zero })
    }
}
