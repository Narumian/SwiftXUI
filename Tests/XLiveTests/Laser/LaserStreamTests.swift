import Foundation
import simd
import XCTest
@testable import XLive

private func point(_ x: Float, lit: Bool = true) -> LaserPoint {
    try! LaserPoint(xy: SIMD2<Float>(x, 0), rgb: lit ? SIMD3<Float>(repeating: 0.5) : .zero, isBlanked: !lit)
}

/// A scanner stream that hands out scripted chunk sizes, whatever it is asked for.
private struct ScriptedStream: LaserOutputStream {
    var format = LaserStreamFormat(domain: .scanner, rate: 30000)
    var sizes: [Int]
    var next = 0
    var asked: [Int] = []
    mutating func read(wanting count: Int) -> LaserChunk<LaserPoint> {
        asked.append(count)
        guard !sizes.isEmpty else { return LaserChunk() }
        let size = sizes.removeFirst()
        defer { next += size }
        return LaserChunk(elements: (next..<next + size).map { point(Float($0) / 1000) }, shape: 7)
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

    func testSliceRebasesRunsAndFrameEnds() {
        var chunk = LaserChunk(elements: Array(0..<10), runs: [LaserRun(id: 1, range: 0..<4), LaserRun(id: 2, range: 4..<10)], frameEnds: [4, 10])
        let middle = chunk.slice(2..<7)
        XCTAssertEqual(middle.elements, [2, 3, 4, 5, 6])
        XCTAssertEqual(middle.runs, [LaserRun(id: 1, range: 0..<2), LaserRun(id: 2, range: 2..<5)])
        XCTAssertEqual(middle.frameEnds, [2])
        XCTAssertEqual(chunk.slice(4..<10).frameEnds, [6])
        XCTAssertEqual(chunk.slice(0..<4).frameEnds, [4])
        XCTAssertTrue(chunk.slice(4..<4).isEmpty)
        chunk = chunk.slice(0..<10)
        XCTAssertEqual(chunk.runs.count, 2)
    }

    func testAppendShiftsAndJoinsARunThatContinuesAcrossTheSeam() {
        var a = LaserChunk(elements: [0, 1], shape: 5)
        a.frameEnds = [2]
        let b = LaserChunk(elements: [2, 3, 4], shape: 5)
        a.append(b)
        XCTAssertEqual(a.runs, [LaserRun(id: 5, range: 0..<5)])
        XCTAssertEqual(a.frameEnds, [2])
        let c = LaserChunk(elements: [5], shape: 6)
        a.append(c)
        XCTAssertEqual(a.runs, [LaserRun(id: 5, range: 0..<5), LaserRun(id: 6, range: 5..<6)])
    }

    func testReaderAsksAgainWhenShortAndStopsOnAnEmptyAnswer() {
        var reader = LaserReader(ScriptedStream(sizes: [3, 4]))
        let out = reader.take(10)
        XCTAssertEqual(out.count, 7)                       // the stream ran dry
        XCTAssertEqual(reader.stream.asked, [10, 7, 3])    // asked again for the shortfall, then an empty answer
        XCTAssertEqual(out.elements.map(\.xy.x), (0..<7).map { Float($0) / 1000 })
        XCTAssertEqual(out.runs, [LaserRun(id: 7, range: 0..<7)])
    }

    func testReaderKeepsSurplusWhenTheStreamReturnsMoreThanWanted() {
        var reader = LaserReader(ScriptedStream(sizes: [10]))
        XCTAssertEqual(reader.take(4).count, 4)
        XCTAssertEqual(reader.surplus, 6)
        let rest = reader.take(6)
        XCTAssertEqual(rest.elements.map(\.xy.x), (4..<10).map { Float($0) / 1000 })
        XCTAssertEqual(reader.stream.asked.count, 1)       // the surplus served the second take
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

    func testFrameLooperRepeatsTheFrameAndSwapsAtTheBoundary() {
        let looper = LaserFrameLooper<Int>(format: LaserStreamFormat(domain: .shapes))
        XCTAssertTrue(looper.read(wanting: 5).isEmpty)     // nothing submitted yet
        looper.submit(LaserChunk(elements: [1, 2, 3], shape: 1))
        let first = looper.read(wanting: 1)                 // the wanted count is only a hint
        XCTAssertEqual(first.elements, [1, 2, 3])
        XCTAssertEqual(first.frameEnds, [3])
        looper.submit(LaserChunk(elements: [9, 9], shape: 2))
        looper.submit(LaserChunk(elements: [8, 8, 8, 8], shape: 3))   // newest waiting frame wins
        let second = looper.read(wanting: 100)
        XCTAssertEqual(second.elements, [8, 8, 8, 8])
        XCTAssertEqual(second.runs, [LaserRun(id: 3, range: 0..<4)])
        XCTAssertEqual(looper.read(wanting: 100).elements, [8, 8, 8, 8])  // loops until replaced
        looper.clear()
        XCTAssertTrue(looper.read(wanting: 4).isEmpty)
    }

    func testReaderOverALoopedFrameFillsABlockAcrossFrameEnds() {
        let looper = LaserFrameLooper<LaserPoint>(format: LaserStreamFormat(domain: .scanner, rate: 30000))
        looper.submit(LaserChunk(elements: [point(0.1), point(0.2), point(0.3)], shape: 4))
        struct Output: LaserOutputStream {
            let looper: LaserFrameLooper<LaserPoint>
            var format: LaserStreamFormat { looper.format }
            mutating func read(wanting count: Int) -> LaserChunk<LaserPoint> { looper.read(wanting: count) }
        }
        var reader = LaserReader(Output(looper: looper))
        let block = reader.take(8)
        XCTAssertEqual(block.count, 8)
        XCTAssertEqual(block.frameEnds, [3, 6])            // two whole frames and a partial third
        XCTAssertEqual(block.runs, [LaserRun(id: 4, range: 0..<8)])
    }
}
