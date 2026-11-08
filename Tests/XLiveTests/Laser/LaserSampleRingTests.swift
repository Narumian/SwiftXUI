import Foundation
import XCTest
@testable import XLive

private func lit(_ x: Float, rgb: Float = 0.5) -> LaserPoint { try! LaserPoint(xy: SIMD2<Float>(x, 0), rgb: SIMD3<Float>(repeating: rgb)) }
private func dark(_ x: Float) -> LaserPoint { try! LaserPoint(xy: SIMD2<Float>(x, 0), rgb: .zero, isBlanked: true) }

final class LaserSampleRingTests: XCTestCase {
    func testPullReturnsPushedSamplesInOrderAcrossWraparound() {
        let ring = LaserSampleRing(capacity: 4)
        let reader = ring.makeReader()
        XCTAssertEqual(ring.tryPush([lit(0.1), lit(0.2), lit(0.3)][...]), 3)
        XCTAssertEqual(reader.pull(2).map(\.xy.x), [0.1, 0.2])
        XCTAssertEqual(ring.tryPush([lit(0.4), lit(0.5), lit(0.6)][...]), 3) // wraps
        XCTAssertEqual(reader.pull(4).map(\.xy.x), [0.3, 0.4, 0.5, 0.6])
        XCTAssertEqual(reader.starvedSamples, 0)
    }

    func testTryPushTakesOnlyWhatFits() {
        let ring = LaserSampleRing(capacity: 3)
        let reader = ring.makeReader()
        XCTAssertEqual(ring.tryPush([lit(0), lit(0), lit(0), lit(0), lit(0)][...]), 3)
        XCTAssertEqual(reader.fill, 3)
        XCTAssertEqual(ring.tryPush([lit(0)][...]), 0)
    }

    func testNothingIsTakenWithoutAReader() {
        let ring = LaserSampleRing(capacity: 3)
        XCTAssertEqual(ring.tryPush([lit(0)][...]), 0)
    }

    func testStarvedPullIsToppedUpWithBlankSamplesAtTheLastPosition() {
        let ring = LaserSampleRing(capacity: 8)
        let reader = ring.makeReader()
        _ = ring.tryPush([lit(0.25), lit(0.75)][...])
        let out = reader.pull(5)
        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(out[0].xy.x, 0.25)
        XCTAssertEqual(out[1].xy.x, 0.75)
        XCTAssertFalse(out[1].isBlanked)
        for point in out.dropFirst(2) { XCTAssertTrue(point.isBlanked && point.rgb == .zero && point.xy.x == 0.75) }
        XCTAssertEqual(reader.starvedSamples, 3)
        XCTAssertEqual(reader.starvedPullCount, 1)
        // Later pulls stay dark at the same place until the producer catches up.
        XCTAssertTrue(reader.pull(2).allSatisfy { $0.isBlanked && $0.xy.x == 0.75 })
    }

    func testEmptyRingNeverEmitsLightAndStartsAtCentre() {
        let out = LaserSampleRing(capacity: 4).makeReader().pull(6)
        XCTAssertTrue(out.allSatisfy { $0.isBlanked && $0.xy == .zero && $0.rgb == .zero })
    }

    func testAsyncPushWaitsForSpaceAndCancellationEndsIt() async throws {
        let ring = LaserSampleRing(capacity: 2)
        let reader = ring.makeReader()
        let producer = Task { try await ring.push([lit(0.1), lit(0.2), lit(0.3), lit(0.4)]) }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(reader.fill, 2) // blocked on the full ring
        XCTAssertEqual(reader.pull(2).map(\.xy.x), [0.1, 0.2])
        _ = try await producer.value
        XCTAssertEqual(reader.pull(2).map(\.xy.x), [0.3, 0.4])
        let blocked = Task { try await ring.push(Array(repeating: lit(0.5), count: 10)) }
        try await Task.sleep(nanoseconds: 20_000_000)
        blocked.cancel()
        do { try await blocked.value; XCTFail("expected cancellation") } catch {}
    }

    func testClearDropsBufferedSamples() {
        let ring = LaserSampleRing(capacity: 4)
        let reader = ring.makeReader()
        _ = ring.tryPush([lit(0.1), lit(0.2)][...])
        ring.clear()
        XCTAssertEqual(reader.fill, 0)
    }

    func testEveryReaderSeesEverySampleOnItsOwnClock() {
        let ring = LaserSampleRing(capacity: 8)
        let a = ring.makeReader(), b = ring.makeReader()
        _ = ring.tryPush([lit(0.1), lit(0.2), lit(0.3), lit(0.4)][...])
        XCTAssertEqual(a.pull(4).map(\.xy.x), [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(b.pull(2).map(\.xy.x), [0.1, 0.2])
        XCTAssertEqual(b.pull(2).map(\.xy.x), [0.3, 0.4])
        XCTAssertEqual(a.starvedSamples + b.starvedSamples, 0)
    }

    func testAReaderStartsAtTheLiveEnd() {
        let ring = LaserSampleRing(capacity: 8)
        let first = ring.makeReader()
        _ = ring.tryPush([lit(0.1), lit(0.2)][...])
        let late = ring.makeReader()
        _ = ring.tryPush([lit(0.3)][...])
        XCTAssertEqual(late.pull(1).map(\.xy.x), [0.3])
        XCTAssertEqual(first.pull(3).map(\.xy.x), [0.1, 0.2, 0.3])
    }

    func testTheProducerIsPacedByTheReaderThatIsAheadAndALaggardSkipsForward() {
        let ring = LaserSampleRing(capacity: 4)
        let fast = ring.makeReader(), slow = ring.makeReader()
        XCTAssertEqual(ring.tryPush([lit(0.1), lit(0.2), lit(0.3), lit(0.4)][...]), 4)
        XCTAssertEqual(ring.tryPush([lit(0.5)][...]), 0) // full for both
        XCTAssertEqual(fast.pull(4).map(\.xy.x), [0.1, 0.2, 0.3, 0.4])
        // The slow reader still holds the buffer's oldest samples, yet the producer goes on.
        XCTAssertEqual(ring.tryPush([lit(0.5), lit(0.6), lit(0.7), lit(0.8)][...]), 4)
        XCTAssertEqual(fast.pull(4).map(\.xy.x), [0.5, 0.6, 0.7, 0.8])
        // The slow reader lost the first four and finds the last four.
        XCTAssertEqual(slow.pull(4).map(\.xy.x), [0.5, 0.6, 0.7, 0.8])
        XCTAssertEqual(slow.skippedSamples, 4)
        XCTAssertEqual(slow.starvedSamples, 0)
    }

    func testARemovedReaderNoLongerHoldsTheProducerUp() {
        let ring = LaserSampleRing(capacity: 2)
        let reader = ring.makeReader()
        XCTAssertEqual(ring.tryPush([lit(0), lit(0)][...]), 2)
        ring.remove(reader)
        XCTAssertEqual(ring.readerCount, 0)
        XCTAssertEqual(ring.tryPush([lit(0)][...]), 0) // nobody is listening
    }
}

final class LaserRateConverterTests: XCTestCase {
    private final class Source {
        var next = 0
        var pulls: [Int] = []
        func pull(_ n: Int) -> [LaserPoint] {
            pulls.append(n)
            defer { next += n }
            return (next..<next + n).map { lit(Float($0) / 10000) }
        }
    }

    func testEqualRatesPassSamplesThroughUntouched() {
        var converter = LaserRateConverter(sourceRate: 30000, outputRate: 30000)
        let source = Source()
        let out = converter.convert(count: 10) { source.pull($0) }
        XCTAssertEqual(out.map(\.xy.x), (0..<10).map { Float($0) / 10000 })
        XCTAssertEqual(source.pulls, [10])
    }

    func testDownsamplingByTwoTakesEverySecondSource() {
        var converter = LaserRateConverter(sourceRate: 30000, outputRate: 15000)
        let source = Source()
        let out = converter.convert(count: 5) { source.pull($0) }
        XCTAssertEqual(out.map(\.xy.x), [0, 0.0002, 0.0004, 0.0006, 0.0008])
    }

    func testUpsamplingInterpolatesBetweenNeighbours() {
        var converter = LaserRateConverter(sourceRate: 10000, outputRate: 20000)
        let source = Source()
        let out = converter.convert(count: 6) { source.pull($0) }
        let expected: [Float] = [0, 0.00005, 0.0001, 0.00015, 0.0002, 0.00025]
        for (a, b) in zip(out.map(\.xy.x), expected) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }

    func testConversionIsContinuousAcrossCallsAndConsumesTheSourceRateExactly() {
        var converter = LaserRateConverter(sourceRate: 30000, outputRate: 20000)
        let source = Source()
        var out: [LaserPoint] = []
        for _ in 0..<30 { out += converter.convert(count: 100) { source.pull($0) } }
        // 3000 output samples advance 1.5 source samples each: 4500 source samples.
        let positions = out.map(\.xy.x)
        for (previous, next) in zip(positions, positions.dropFirst()) { XCTAssertGreaterThan(next, previous) }
        XCTAssertEqual(positions.last!, Float(2999) * 1.5 / 10000, accuracy: 0.0002)
        XCTAssertGreaterThanOrEqual(source.next, 4500)
        XCTAssertLessThan(source.next, 4500 + 64 + 2)
    }

    func testAnEdgeBetweenLitAndBlankedStaysDark() {
        var converter = LaserRateConverter(sourceRate: 10000, outputRate: 20000)
        let samples = [lit(0.0), dark(0.1), dark(0.2), dark(0.3)]
        var index = 0
        let out = converter.convert(count: 4) { n in defer { index += n }; return (index..<index + n).map { samples[min($0, 3)] } }
        XCTAssertFalse(out[0].isBlanked)
        XCTAssertTrue(out[1].isBlanked) // between lit and blanked
        XCTAssertTrue(out[2].isBlanked)
    }

    func testInterpolatedColourStaysInRange() {
        var converter = LaserRateConverter(sourceRate: 7919, outputRate: 30000)
        let out = converter.convert(count: 5000) { n in Array(repeating: lit(1, rgb: 1), count: n) }
        XCTAssertEqual(out.count, 5000)
        XCTAssertTrue(out.allSatisfy { $0.rgb.x <= 1 && $0.xy.x <= 1 })
    }
}
