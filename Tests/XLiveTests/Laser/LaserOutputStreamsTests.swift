import Foundation
import XCTest
@testable import XLive

private actor Recorder {
    var starts = 0, stops = 0, interrupts = 0, litWrites = 0, blackWrites = 0
    func start() { starts += 1 }
    func disconnect() { stops += 1 }
    func interrupt() { interrupts += 1 }
    func write(_ points: [LaserPoint]) {
        if points.contains(where: { !$0.isBlanked }) { litWrites += 1 } else { blackWrites += 1 }
    }
}

private final class StubSession: LaserOutputSession, @unchecked Sendable {
    let recorder: Recorder
    let capabilities = LaserOutputCapabilities(maximumPointRate: 30000)
    let states = AsyncStream<LaserOutputState> { $0.finish() }
    init(_ recorder: Recorder) { self.recorder = recorder }
    func start(pointRate: UInt32) async throws { await recorder.start() }
    func write(_ points: [LaserPoint]) async throws { await recorder.write(points) }
    func stop() async throws { await recorder.interrupt() }
    func disconnect() async throws { await recorder.disconnect() }
}

final class LaserOutputStreamsTests: XCTestCase, @unchecked Sendable {
    func testBlackCenterIsOnlyBlankCenterPoints() {
        let points = LaserPoint.blackCenter(count: 280)
        XCTAssertEqual(points.count, 280)
        XCTAssertTrue(points.allSatisfy { $0.xy == .zero && $0.rgb == .zero && $0.isBlanked })
    }

    func testStreamsAreIndependentByID() async throws {
        let recorder = Recorder()
        let streams = LaserOutputStreams()
        let first = UUID(), second = UUID()
        try await streams.connect(first) { StubSession(recorder) }
        try await streams.connect(second) { StubSession(recorder) }
        let firstConnected = await streams.hasSession(first)
        XCTAssertTrue(firstConnected)
        try await streams.disconnect(first)
        let firstGone = await streams.hasSession(first), secondKept = await streams.hasSession(second)
        XCTAssertFalse(firstGone)
        XCTAssertTrue(secondKept)
        let stoppedOnce = await recorder.stops
        XCTAssertEqual(stoppedOnce, 1)
        try await streams.disconnect(second)
        let stoppedTwice = await recorder.stops
        XCTAssertEqual(stoppedTwice, 2)
    }

    func testIdleStreamsBlackThenPatternPlaysAndStopInterruptsAndRestarts() async throws {
        let recorder = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let id = UUID()
        try await streams.connect(id) { StubSession(recorder) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let idleBlack = await recorder.blackWrites, idleLit = await recorder.litWrites
        XCTAssertGreaterThan(idleBlack, 0)
        XCTAssertEqual(idleLit, 0)
        let lit = try LaserPoint(xy: .zero, rgb: SIMD3<Float>(repeating: 0.1))
        try await streams.play([lit], for: id)
        for _ in 0..<200 {
            if await recorder.litWrites > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let litWrites = await recorder.litWrites, active = await streams.patternActive(id)
        XCTAssertGreaterThan(litWrites, 0)
        XCTAssertTrue(active)
        try await streams.stopPattern(for: id)
        let activeAfter = await streams.patternActive(id), interrupts = await recorder.interrupts, starts = await recorder.starts
        XCTAssertFalse(activeAfter)
        XCTAssertGreaterThanOrEqual(interrupts, 1)
        XCTAssertGreaterThanOrEqual(starts, 2)
        try await streams.disconnect(id)
    }

    func testReplacingAStoppedPatternDoesNotRevive() async throws {
        let recorder = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let id = UUID()
        try await streams.connect(id) { StubSession(recorder) }
        let lit = try LaserPoint(xy: .zero, rgb: SIMD3<Float>(repeating: 0.1))
        try await streams.play([lit], for: id)
        try await streams.stopPattern(for: id)
        await streams.replacePattern([lit], for: id)
        let active = await streams.patternActive(id)
        XCTAssertFalse(active)
        try await streams.disconnect(id)
    }

    func testOperationsOnAnUnknownIDThrowNotConnected() async {
        let streams = LaserOutputStreams()
        do { try await streams.play([], for: UUID()); XCTFail("expected notConnected") } catch {
            guard case LaserStreamError.notConnected = error else { return XCTFail("\(error)") }
        }
    }

    func testASourceIsPulledThroughTheRingAndStopInterruptsAndRestartsBlack() async throws {
        let recorder = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let id = UUID()
        try await streams.connect(id) { StubSession(recorder) }
        let lit = try LaserPoint(xy: .zero, rgb: SIMD3<Float>(repeating: 0.1))
        let dark = try LaserPoint(xy: .zero, rgb: .zero, isBlanked: true)
        let chunks = AsyncStream<[LaserPoint]> { continuation in
            Task { while !Task.isCancelled { continuation.yield(Array(repeating: lit, count: 139) + [dark]); try? await Task.sleep(nanoseconds: 2_000_000) } ; continuation.finish() }
        }
        try await streams.play(source: chunks, sampleRate: 30000, for: id)
        let active = await streams.sourceActive(id)
        XCTAssertTrue(active)
        for _ in 0..<200 {
            if await recorder.litWrites > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let litWrites = await recorder.litWrites
        XCTAssertGreaterThan(litWrites, 0)
        try await streams.stopPattern(for: id)
        let stillActive = await streams.sourceActive(id), interrupts = await recorder.interrupts, starts = await recorder.starts
        XCTAssertFalse(stillActive)
        XCTAssertGreaterThanOrEqual(interrupts, 1)
        XCTAssertGreaterThanOrEqual(starts, 2)
        try await streams.disconnect(id)
    }

    func testAStarvedSourceGoesDarkWithoutFailingTheStream() async throws {
        let recorder = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let id = UUID()
        try await streams.connect(id) { StubSession(recorder) }
        let silent = AsyncStream<[LaserPoint]> { _ in }   // never yields
        try await streams.play(source: silent, sampleRate: 30000, for: id)
        try await Task.sleep(nanoseconds: 80_000_000)
        let lit = await recorder.litWrites, black = await recorder.blackWrites, failure = await streams.streamFailure(id)
        XCTAssertEqual(lit, 0)
        XCTAssertGreaterThan(black, 0)
        XCTAssertNil(failure)
        let report = await streams.diagnosticsReport()
        XCTAssertTrue(report.contains("starved="), report)
        try await streams.disconnect(id)
    }

    func testASourceOnOneOutputDoesNotHoldUpAnother() async throws {
        let slowRecorder = Recorder(), fastRecorder = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let slow = UUID(), fast = UUID()
        try await streams.connect(slow) { StubSession(slowRecorder) }
        try await streams.connect(fast) { StubSession(fastRecorder) }
        let silent = AsyncStream<[LaserPoint]> { _ in }
        try await streams.play(source: silent, sampleRate: 30000, for: slow)
        try await Task.sleep(nanoseconds: 100_000_000)
        let slowWrites = await slowRecorder.blackWrites, fastWrites = await fastRecorder.blackWrites
        XCTAssertGreaterThan(slowWrites, 3)   // the starved output keeps being fed (dark)
        XCTAssertGreaterThan(fastWrites, 3)   // and so does the idle one
        try await streams.disconnect(slow)
        try await streams.disconnect(fast)
    }
}
