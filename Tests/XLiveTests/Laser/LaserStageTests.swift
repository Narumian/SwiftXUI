import Foundation
import simd
import XCTest
@testable import XLive

private func point(_ x: Float, _ mode: LaserPointMode = .normal, lit: Float = 1) -> LaserPoint {
    try! LaserPoint(xy: SIMD2(x, 0), rgb: SIMD3(repeating: mode == .blank ? 0 : lit), mode: mode)
}
private func shape(_ id: UInt32, _ points: [LaserPoint]) -> [Laser2DShape] { [Laser2DShape(id: LaserShapeID(id), points: points)] }
private func flat(_ shapes: [Laser2DShape]) -> [LaserPoint] { shapes.flatMap(\.points) }

final class LaserDwellBlankTests: XCTestCase {
    func testAShapeGetsBlankAndDwellBeforeAndDwellAndOneBlankAfter() {
        var stage = LaserDwellBlank(dwell: 2, blank: 3)
        let out = stage.process(shape(4, [point(0.1), point(0.2)]))
        XCTAssertEqual(flat(out).map(\.mode), [.blank, .blank, .blank, .dwell, .dwell, .normal, .normal, .dwell, .dwell, .blank])
        XCTAssertEqual(flat(out).map(\.xy.x), [0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.2, 0.2, 0.2, 0.2])
        XCTAssertEqual(out.map(\.id), [4])
    }

    func testEachShapeIsPaddedOnItsOwnAndKeepsItsIdentity() {
        var stage = LaserDwellBlank(dwell: 1, blank: 1)
        let out = stage.process(shape(1, [point(0.1), point(0.2)]) + shape(2, [point(0.3)]))
        // shape 1: blank dwell a b dwell blank = 6; shape 2: blank dwell c dwell blank = 5
        XCTAssertEqual(out.map(\.id), [1, 2])
        XCTAssertEqual(out.map(\.points.count), [6, 5])
    }

    func testAnEndThatIsNotNormalGetsNoPadding() {
        var stage = LaserDwellBlank(dwell: 2, blank: 2)
        let out = stage.process(shape(1, [point(0.1, .blank), point(0.2), point(0.3, .dwell)]))
        XCTAssertEqual(flat(out).map(\.mode), [.blank, .normal, .dwell])
    }

    func testEachEndIsJudgedByItself() {
        var stage = LaserDwellBlank(dwell: 1, blank: 1)
        let out = stage.process(shape(1, [point(0.1), point(0.2, .blank)]))
        XCTAssertEqual(flat(out).map(\.mode), [.blank, .dwell, .normal, .blank])
    }

    func testNoPaddingConfiguredLeavesTheShapesAlone() {
        var stage = LaserDwellBlank(dwell: 0, blank: 0)
        let frame = shape(1, [point(0.1)])
        XCTAssertEqual(stage.process(frame), frame)
    }
}

final class LaserResamplerTests: XCTestCase {
    /// A resampler that has already left the centre, so a test sees only the move it is about.
    private func settled(_ resampler: inout LaserResampler, at x: Float = -0.5) {
        _ = resampler.process(shape(0, [point(x)]))
    }

    func testALongMoveBetweenDrawnSamplesIsFilledInAndColourIsMixed() {
        var resampler = LaserResampler(maximumStep: 0.25)
        settled(&resampler)
        let out = flat(resampler.process(shape(1, [point(-0.5, lit: 0.0), point(0.5, lit: 1)])))
        // length 1 / 0.25 = 4 samples are inserted, evenly, then the end; the first sample is
        // a move of zero length, which comes out as the sample twice (Legacy's INTER + [dst])
        XCTAssertEqual(out.count, 2 + 4 + 1)
        XCTAssertEqual(out.suffix(5).map(\.xy.x).map { ($0 * 10).rounded() / 10 }, [-0.3, -0.1, 0.1, 0.3, 0.5])
        XCTAssertEqual(out[out.count - 4].rgb.x, 0.4, accuracy: 1e-6)
        XCTAssertTrue(out.suffix(5).dropLast().allSatisfy { $0.mode == .normal })
    }

    func testTheFirstSampleStartsFromTheDarkCentre() {
        var resampler = LaserResampler(maximumStep: 0.25)
        let out = flat(resampler.process(shape(1, [point(0.5, lit: 1)])))
        // 0.5 from the centre: 2 samples inserted at 1/3 and 2/3 of the way, colour rising from black
        XCTAssertEqual(out.count, 2 + 1)
        XCTAssertEqual(out[0].xy.x, 0.5 / 3, accuracy: 1e-6)
        XCTAssertEqual(out[0].rgb.x, 1.0 / 3, accuracy: 1e-6)
    }

    func testCloseDrawnSamplesAreMerged() {
        var resampler = LaserResampler(minimumStep: 0.1, maximumStep: 1)
        settled(&resampler, at: 0)
        let out = flat(resampler.process(shape(1, [point(0.02), point(0.05), point(0.2)])))
        XCTAssertEqual(out.map(\.xy.x), [0.2, 0.2])    // 0.02 and 0.05 are within 0.1 of the kept 0; a short move is the sample twice
    }

    func testAMoveBetweenSamplesThatAreNotBothDrawnIsASingleJump() {
        var resampler = LaserResampler(maximumStep: 0.1)
        _ = resampler.process(shape(0, [point(0, .blank)]))           // now the previous sample is not a drawn one
        let out = flat(resampler.process(shape(1, [point(-0.8, .blank), point(0.8, .dwell), point(0.8, .blank)])))
        XCTAssertEqual(out.count, 3)                                // each move is the destination alone
    }

    func testTheMaximumInsertedCapsTheFill() {
        var resampler = LaserResampler(maximumStep: 0.001, maximumInserted: 5)
        settled(&resampler, at: -1)
        XCTAssertEqual(flat(resampler.process(shape(1, [point(1)]))).count, 5 + 1)
    }

    func testStateCarriesAcrossShapesSoTheMoveBetweenThemBelongsToTheNextOne() {
        var resampler = LaserResampler(maximumStep: 0.5)
        settled(&resampler)
        let out = resampler.process(shape(1, [point(0.5)]) + shape(2, [point(-0.5)]))
        XCTAssertEqual(out.map(\.id), [1, 2])
        XCTAssertEqual(out.map(\.points.count), [2 + 1, 2 + 1])
    }

    func testResetGoesBackToTheDarkCentre() {
        var resampler = LaserResampler(maximumStep: 0.25)
        settled(&resampler, at: 0.9)
        resampler.reset()
        XCTAssertEqual(flat(resampler.process(shape(1, [point(0.5)]))).count, 2 + 1)
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
        let stage = LaserMasking(square(dimmer: 0))
        let points = [point(0), point(0.9), point(0, .dwell)]
        let out = stage.apply(points)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].rgb, .zero)                 // the centre is masked
        XCTAssertEqual(out[0].xy, points[0].xy)
        XCTAssertEqual(out[1], points[1])                 // outside is the same sample
        XCTAssertEqual(out[2].rgb, .zero)
        XCTAssertEqual(out[2].mode, .dwell)
    }

    func testADimmerLeavesThatFractionOfTheLight() {
        let stage = LaserMasking(square(dimmer: 0.25))
        XCTAssertEqual(stage.apply([point(0)])[0].rgb.x, 0.25, accuracy: 1e-6)
    }

    func testMasksThatAreOffOrAbsentPassTheSamplesThrough() {
        var disabled = square(dimmer: 0)
        disabled.masks[0].enabled = false
        let points = [point(0)]
        XCTAssertEqual(LaserMasking(disabled).apply(points), points)
        XCTAssertEqual(LaserMasking(LaserMaskSettings()).apply(points), points)
    }
}

final class LaserCornerDwellTests: XCTestCase {
    private func p(_ x: Float, _ y: Float, _ mode: LaserPointMode = .normal) -> LaserPoint {
        try! LaserPoint(xy: SIMD2(x, y), rgb: mode == .blank ? .zero : SIMD3(repeating: 0.5), mode: mode)
    }

    func testARightAngleGetsHalfTheMaximumAndTheHoldsStayOnTheCorner() {
        var stage = LaserCornerDwell(maximum: 8)
        let out = flat(stage.process(shape(2, [p(-0.5, 0), p(0, 0), p(0, 0.5)])))
        XCTAssertEqual(out.map(\.mode), [.normal, .normal, .dwell, .dwell, .dwell, .dwell, .normal])
        XCTAssertTrue(out[2...5].allSatisfy { $0.xy == SIMD2<Float>(0, 0) && $0.rgb == SIMD3<Float>(repeating: 0.5) })
    }

    func testAFullReversalGetsTheMaximumAndAGentleTurnGetsNothing() {
        var stage = LaserCornerDwell(maximum: 8)
        XCTAssertEqual(flat(stage.process(shape(1, [p(-0.5, 0), p(0, 0), p(-0.5, 0)]))).count, 3 + 8)
        // a 10 degree turn is under the 20 degree threshold
        XCTAssertEqual(flat(stage.process(shape(1, [p(-0.5, 0), p(0, 0), p(0.5, 0.088)]))).count, 3)
    }

    func testTheSharperTheTurnTheMoreDwell() {
        var stage = LaserCornerDwell(maximum: 10)
        func hold(_ degrees: Double) -> Int {
            let turn = degrees * .pi / 180
            let end = p(Float(0.5 * cos(turn)), Float(0.5 * sin(turn)))
            return flat(stage.process(shape(1, [p(-0.5, 0), p(0, 0), end]))).count - 3
        }
        XCTAssertLessThan(hold(30), hold(60))
        XCTAssertLessThan(hold(60), hold(120))
    }

    func testEndsBlankNeighboursExistingDwellAndZeroLengthEdgesAreNotCorners() {
        var stage = LaserCornerDwell(maximum: 8)
        // the ends of the shape
        XCTAssertEqual(flat(stage.process(shape(1, [p(0, 0), p(0.5, 0), p(0.5, 0.5)]))).count, 3 + 4)
        // a corner next to a blank sample, or that is already a dwell
        XCTAssertEqual(flat(stage.process(shape(1, [p(-0.5, 0, .blank), p(0, 0), p(0, 0.5)]))).count, 3)
        XCTAssertEqual(flat(stage.process(shape(1, [p(-0.5, 0), p(0, 0, .dwell), p(0, 0.5)]))).count, 3)
        XCTAssertEqual(LaserCornerDwell(maximum: 0).maximum, 0)
    }

    func testEachShapeIsHandledOnItsOwn() {
        var stage = LaserCornerDwell(maximum: 8)
        // two shapes of 2 points each: neither has an interior vertex, so no corner across the seam
        let frame = shape(1, [p(-0.5, 0), p(0, 0)]) + shape(2, [p(0, 0.5), p(0.5, 0.5)])
        XCTAssertEqual(flat(stage.process(frame)).count, 4)
    }
}

final class LaserMasteringTests: XCTestCase {
    func testThePlaceholderPassesShapesThroughUntouched() {
        let mastering = LaserMastering()
        let frame = [Laser3DShape(id: 3, vertices: [LaserVertex(x: 0.1, y: 0.2, z: 0.3), LaserVertex(x: -0.1, y: 0)])]
        XCTAssertEqual(mastering.process(frame), frame)
        XCTAssertTrue(mastering.process([]).isEmpty)
        let effect: any LaserEffect = mastering          // a master filter is a laser effect like any other
        XCTAssertEqual(effect.process(frame), frame)
    }
}
