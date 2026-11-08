import Foundation
import simd
import XCTest
@testable import XLive

private func vertex(_ x: Double, mode: LaserPointMode = .normal) -> LaserVertex {
    LaserVertex(x: x, y: 0, rgba: mode == .blank ? .zero : .one, mode: mode)
}
private func point(_ x: Float, _ mode: LaserPointMode = .normal, lit: Float = 1) -> LaserPoint {
    try! LaserPoint(xy: SIMD2(x, 0), rgb: SIMD3(repeating: mode == .blank ? 0 : lit), mode: mode)
}

final class LaserDwellBlankTests: XCTestCase {
    func testAShapeGetsBlankAndDwellBeforeAndDwellAndOneBlankAfter() {
        var stage = LaserDwellBlank(dwell: 2, blank: 3)
        let out = stage.process(LaserChunk(elements: [vertex(0.1), vertex(0.2)], shape: 4))
        XCTAssertEqual(out.elements.map(\.mode), [.blank, .blank, .blank, .dwell, .dwell, .normal, .normal, .dwell, .dwell, .blank])
        XCTAssertEqual(out.elements.map(\.position.x), [0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.2, 0.2, 0.2, 0.2])
        XCTAssertEqual(out.runs, [LaserRun(id: 4, range: 0..<10)])
    }

    func testEachRunIsPaddedOnItsOwnAndFrameEndsFollow() {
        var stage = LaserDwellBlank(dwell: 1, blank: 1)
        let chunk = LaserChunk(elements: [vertex(0.1), vertex(0.2), vertex(0.3)],
                               runs: [LaserRun(id: 1, range: 0..<2), LaserRun(id: 2, range: 2..<3)], frameEnds: [3])
        let out = stage.process(chunk)
        // shape 1: blank dwell a b dwell blank = 6; shape 2: blank dwell c dwell blank = 5
        XCTAssertEqual(out.count, 11)
        XCTAssertEqual(out.runs, [LaserRun(id: 1, range: 0..<6), LaserRun(id: 2, range: 6..<11)])
        XCTAssertEqual(out.frameEnds, [11])
    }

    func testAnEndThatIsNotNormalGetsNoPadding() {
        var stage = LaserDwellBlank(dwell: 2, blank: 2)
        let out = stage.process(LaserChunk(elements: [vertex(0.1, mode: .blank), vertex(0.2), vertex(0.3, mode: .dwell)], shape: 1))
        XCTAssertEqual(out.elements.map(\.mode), [.blank, .normal, .dwell])
    }

    func testNoPaddingConfiguredLeavesTheChunkAlone() {
        var stage = LaserDwellBlank(dwell: 0, blank: 0)
        let chunk = LaserChunk(elements: [vertex(0.1)], shape: 1)
        XCTAssertEqual(stage.process(chunk).elements, chunk.elements)
    }

    func testAChunkWithoutRunsIsOneShape() {
        var stage = LaserDwellBlank(dwell: 1, blank: 1)
        XCTAssertEqual(stage.process(LaserChunk(elements: [vertex(0.1), vertex(0.2)])).count, 6)
    }
}

final class LaserSamplerTests: XCTestCase {
    func testALongMoveBetweenDrawnSamplesIsFilledInAndColourIsMixed() {
        var sampler = LaserSampler(maximumStep: 0.25)
        let out = sampler.process(LaserChunk(elements: [point(-0.5, lit: 0), point(0.5, lit: 1)], shape: 1))
        // the first sample passes; length 1 / 0.25 = 4 samples are inserted, evenly, then the end
        XCTAssertEqual(out.elements.map(\.xy.x).map { ($0 * 10).rounded() / 10 }, [-0.5, -0.3, -0.1, 0.1, 0.3, 0.5])
        XCTAssertEqual(out.elements[2].rgb.x, 0.4, accuracy: 1e-6)
        XCTAssertTrue(out.elements.dropFirst().dropLast().allSatisfy { $0.mode == .normal })
    }

    func testCloseDrawnSamplesAreMerged() {
        var sampler = LaserSampler(minimumStep: 0.1, maximumStep: 1)
        let out = sampler.process(LaserChunk(elements: [point(0), point(0.02), point(0.05), point(0.2)], shape: 1))
        XCTAssertEqual(out.elements.map(\.xy.x), [0, 0.2])    // 0.02 and 0.05 are within 0.1 of the kept 0
    }

    func testAMoveBetweenSamplesThatAreNotBothDrawnIsASingleJump() {
        var sampler = LaserSampler(maximumStep: 0.1)
        let out = sampler.process(LaserChunk(elements: [point(-0.8, .blank), point(0.8, .dwell), point(0.8, .blank)], shape: 1))
        XCTAssertEqual(out.count, 3)
    }

    func testAMoveToABlankSampleIsFilledInDarkInsteadOfFadingOut() {
        var sampler = LaserSampler(maximumStep: 0.5)
        let out = sampler.process(LaserChunk(elements: [point(-0.5), point(0.5, .blank)], shape: 1))
        XCTAssertEqual(out.count, 1 + 2 + 1)          // 2 inserted, then the blank end
        XCTAssertTrue(out.elements.dropFirst().allSatisfy { $0.rgb == .zero && $0.mode == .blank })
    }

    func testAMoveFromABlankSampleIsDrawnInTheArrivingColourInsteadOfFadingIn() {
        var sampler = LaserSampler(maximumStep: 0.5)
        let out = sampler.process(LaserChunk(elements: [point(-0.5, .blank), point(0.5, lit: 0.8)], shape: 1))
        XCTAssertEqual(out.count, 1 + 2 + 1)
        XCTAssertTrue(out.elements.dropFirst().allSatisfy { $0.rgb.x == 0.8 && $0.mode == .normal })
    }

    func testTheMaximumInsertedCapsTheFill() {
        var sampler = LaserSampler(maximumStep: 0.001, maximumInserted: 5)
        XCTAssertEqual(sampler.process(LaserChunk(elements: [point(-1), point(1)], shape: 1)).count, 1 + 5 + 1)
    }

    func testStateAndRunsCarryAcrossChunksAndInsertionsStayInTheirRun() {
        var sampler = LaserSampler(maximumStep: 0.5)
        _ = sampler.process(LaserChunk(elements: [point(-0.5)], shape: 1))
        let out = sampler.process(LaserChunk(elements: [point(0.5)], shape: 1))
        XCTAssertEqual(out.count, 3)                                   // the move from the previous chunk is filled
        XCTAssertEqual(out.runs, [LaserRun(id: 1, range: 0..<3)])
    }

    func testAStagedStreamRunsDwellBlankThenProjectionThenSamplingEndToEnd() {
        var camera = matrix_identity_double4x4
        camera.columns.3 = SIMD4(0, 0, 2, 1)
        let projection = LaserProjection(camera: camera,
                                         projection: LaserProjection.perspective(fovxDegrees: 90, near: 0.1, far: 50),
                                         dwell: 2, blank: 2)
        let looper = LaserFrameLooper<LaserVertex>(format: LaserStreamFormat(domain: .shapes))
        looper.submit(LaserChunk(elements: [vertex(0.4), vertex(-0.4)], shape: 5))
        let padded = LaserStagedStream(looper, stage: LaserDwellBlank(dwell: 2, blank: 2), format: LaserStreamFormat(domain: .shapes))
        let projected = LaserStagedStream(padded, stage: LaserProjector(projection), format: LaserStreamFormat(domain: .scanner, rate: 30000))
        let sampled = LaserStagedStream(projected, stage: LaserSampler(maximumStep: 0.05), format: projected.format)
        var reader = LaserReader(sampled)
        let frame = reader.take(20)
        XCTAssertGreaterThanOrEqual(frame.count, 20)
        XCTAssertFalse(frame.frameEnds.isEmpty)
        XCTAssertEqual(frame.runs.first?.id, 5)
        // the drawn stretch between the two vertices (0.4 apart) was filled to <= 0.05 spacing
        let first = frame.slice(0..<frame.frameEnds[0])
        let drawn = first.elements.filter { $0.mode == .normal }
        XCTAssertEqual(drawn.count, 10)
        for (a, b) in zip(drawn, drawn.dropFirst()) { XCTAssertLessThanOrEqual(abs(b.xy.x - a.xy.x), 0.05 + 1e-5) }
    }
}

final class LaserMaskingTests: XCTestCase {
    private func square(dimmer: Double) -> LaserMaskSettings {
        // The centre of the output area, 0.4...0.6 each way.
        var mask = LaserMask(shape: .polygon, points: [.init(0.4, 0.4), .init(0.6, 0.4), .init(0.6, 0.6), .init(0.4, 0.6)])
        mask.dimmer = dimmer
        return LaserMaskSettings(masks: [mask])
    }

    func testLightIsCutInsideAMaskAndUntouchedOutsideKeepingEverythingElse() {
        var stage = LaserMasking(square(dimmer: 0))
        let chunk = LaserChunk(elements: [point(0), point(0.9), point(0, .dwell)], runs: [LaserRun(id: 3, range: 0..<3)], frameEnds: [3])
        let out = stage.process(chunk)
        XCTAssertEqual(out.elements[0].rgb, .zero)                 // the centre is masked
        XCTAssertEqual(out.elements[0].xy, chunk.elements[0].xy)
        XCTAssertEqual(out.elements[1], chunk.elements[1])         // outside is the same sample
        XCTAssertEqual(out.elements[2].rgb, .zero)
        XCTAssertEqual(out.elements[2].mode, .dwell)
        XCTAssertEqual(out.runs, chunk.runs)
        XCTAssertEqual(out.frameEnds, chunk.frameEnds)
    }

    func testADimmerLeavesThatFractionOfTheLight() {
        var stage = LaserMasking(square(dimmer: 0.25))
        XCTAssertEqual(stage.process(LaserChunk(elements: [point(0)], shape: 1)).elements[0].rgb.x, 0.25, accuracy: 1e-6)
    }

    func testMasksThatAreOffOrAbsentPassTheChunkThrough() {
        var disabled = square(dimmer: 0)
        disabled.masks[0].enabled = false
        let chunk = LaserChunk(elements: [point(0)], shape: 1)
        var off = LaserMasking(disabled), none = LaserMasking(LaserMaskSettings())
        XCTAssertEqual(off.process(chunk).elements, chunk.elements)
        XCTAssertEqual(none.process(chunk).elements, chunk.elements)
    }
}
