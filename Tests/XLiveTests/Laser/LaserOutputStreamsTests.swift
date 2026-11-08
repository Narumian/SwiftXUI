import Foundation
import simd
import XCTest
@testable import XLive

private actor Recorder {
    var starts = 0, stops = 0, interrupts = 0, litWrites = 0, blackWrites = 0, glowWrites = 0
    func start() { starts += 1 }
    func disconnect() { stops += 1 }
    func interrupt() { interrupts += 1 }
    func write(_ points: [LaserPoint]) {
        if points.contains(where: { !$0.isBlanked }) { litWrites += 1 } else { blackWrites += 1 }
        if points.contains(where: { $0.rgb != .zero }) { glowWrites += 1 }
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
        try await streams.play(source: chunks, sampleRate: 30000)
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
        try await streams.play(source: silent, sampleRate: 30000)
        try await Task.sleep(nanoseconds: 80_000_000)
        let lit = await recorder.litWrites, black = await recorder.blackWrites, failure = await streams.streamFailure(id)
        XCTAssertEqual(lit, 0)
        XCTAssertGreaterThan(black, 0)
        XCTAssertNil(failure)
        let report = await streams.diagnosticsReport()
        XCTAssertTrue(report.contains("starved="), report)
        try await streams.disconnect(id)
    }

    private func litChunks() -> AsyncStream<[LaserPoint]> {
        let lit = try! LaserPoint(xy: .zero, rgb: SIMD3<Float>(repeating: 0.1))
        let dark = try! LaserPoint(xy: .zero, rgb: .zero, isBlanked: true)
        return AsyncStream<[LaserPoint]> { continuation in
            Task { while !Task.isCancelled { continuation.yield(Array(repeating: lit, count: 139) + [dark]); try? await Task.sleep(nanoseconds: 2_000_000) }; continuation.finish() }
        }
    }
    private func waitForLight(_ recorder: Recorder) async throws {
        for _ in 0..<300 {
            if await recorder.glowWrites > 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testOneSourceIsPlayedOnEveryConnectedOutput() async throws {
        let first = Recorder(), second = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let a = UUID(), b = UUID()
        try await streams.connect(a) { StubSession(first) }
        try await streams.connect(b) { StubSession(second) }
        try await streams.play(source: litChunks(), sampleRate: 30000)
        try await waitForLight(first); try await waitForLight(second)
        let lightA = await first.glowWrites, lightB = await second.glowWrites
        let activeA = await streams.sourceActive(a), activeB = await streams.sourceActive(b)
        XCTAssertGreaterThan(lightA, 0)
        XCTAssertGreaterThan(lightB, 0)
        XCTAssertTrue(activeA && activeB)
        await streams.stopSource()
        let stillA = await streams.sourceActive(a), stillB = await streams.sourceActive(b)
        XCTAssertFalse(stillA || stillB)
        try await streams.disconnect(a); try await streams.disconnect(b)
    }

    func testAnOutputThatConnectsWhileTheSourcePlaysJoinsIt() async throws {
        let first = Recorder(), late = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let a = UUID(), b = UUID()
        try await streams.connect(a) { StubSession(first) }
        try await streams.play(source: litChunks(), sampleRate: 30000)
        try await waitForLight(first)
        try await streams.connect(b) { StubSession(late) }
        try await waitForLight(late)
        let light = await late.glowWrites
        XCTAssertGreaterThan(light, 0)
        await streams.stopSource()
        try await streams.disconnect(a); try await streams.disconnect(b)
    }

    func testEachOutputAppliesItsOwnMasksAfterTheBuffer() async throws {
        let masked = Recorder(), open = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let a = UUID(), b = UUID()
        var mask = LaserMask(shape: .polygon, points: [.init(0.4, 0.4), .init(0.6, 0.4), .init(0.6, 0.6), .init(0.4, 0.6)])
        mask.dimmer = 0
        try await streams.connect(a, masks: LaserMaskSettings(masks: [mask])) { StubSession(masked) }
        try await streams.connect(b) { StubSession(open) }
        try await streams.play(source: litChunks(), sampleRate: 30000)
        try await waitForLight(open)
        try await Task.sleep(nanoseconds: 50_000_000)
        let maskedLight = await masked.glowWrites, openLight = await open.glowWrites
        XCTAssertEqual(maskedLight, 0)
        XCTAssertGreaterThan(openLight, 0)
        // Edited while playing: clearing the masks lets the light through.
        await streams.setMasks(LaserMaskSettings(), for: a)
        try await waitForLight(masked)
        let after = await masked.glowWrites
        XCTAssertGreaterThan(after, 0)
        await streams.stopSource()
        try await streams.disconnect(a); try await streams.disconnect(b)
    }

    func testStoppingOneOutputLeavesTheOthersPlaying() async throws {
        let first = Recorder(), second = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let a = UUID(), b = UUID()
        try await streams.connect(a) { StubSession(first) }
        try await streams.connect(b) { StubSession(second) }
        try await streams.play(source: litChunks(), sampleRate: 30000)
        try await waitForLight(first); try await waitForLight(second)
        try await streams.stopPattern(for: a)
        let stoppedA = await streams.sourceActive(a), stillB = await streams.sourceActive(b)
        XCTAssertFalse(stoppedA)
        XCTAssertTrue(stillB)
        let before = await second.glowWrites
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterB = await second.glowWrites
        XCTAssertGreaterThan(afterB, before)
        await streams.stopSource()
        try await streams.disconnect(a); try await streams.disconnect(b)
    }

    func testASilentSourceKeepsEveryOutputFedDark() async throws {
        let first = Recorder(), second = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let a = UUID(), b = UUID()
        try await streams.connect(a) { StubSession(first) }
        try await streams.connect(b) { StubSession(second) }
        try await streams.play(source: AsyncStream<[LaserPoint]> { _ in }, sampleRate: 30000)
        try await Task.sleep(nanoseconds: 100_000_000)
        let writesA = await first.blackWrites, writesB = await second.blackWrites
        XCTAssertGreaterThan(writesA, 3)
        XCTAssertGreaterThan(writesB, 3)
        await streams.stopSource()
        try await streams.disconnect(a); try await streams.disconnect(b)
    }
}

final class LaserOutputStreamsStreamTests: XCTestCase, @unchecked Sendable {
    private func projection() -> LaserProjection {
        var camera = matrix_identity_double4x4
        camera.columns.3 = SIMD4(0, 0, 2, 1)
        return LaserProjection(camera: camera,
                               projection: LaserProjection.perspective(fovxDegrees: 90, near: 0.1, far: 50),
                               dwell: 2, blank: 2)
    }

    func testAStageChainPlaysOnAnOutputAndStopsCleanly() async throws {
        let recorder = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let id = UUID()
        try await streams.connect(id) { StubSession(recorder) }
        let looper = LaserFrameLooper<LaserVertex>(format: LaserStreamFormat(domain: .shapes))
        looper.submit(LaserChunk(elements: [LaserVertex(x: 0.4, y: 0), LaserVertex(x: -0.4, y: 0)], shape: 1))
        let padded = LaserStagedStream(looper, stage: LaserDwellBlank(dwell: 2, blank: 2), format: LaserStreamFormat(domain: .shapes))
        let projected = LaserStagedStream(padded, stage: LaserProjector(projection()), format: LaserStreamFormat(domain: .scanner, rate: 30000))
        let sampled = LaserStagedStream(projected, stage: LaserSampler(maximumStep: 0.05), format: projected.format)
        try await streams.play(stream: sampled)
        for _ in 0..<200 {
            if await recorder.litWrites > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let lit = await recorder.litWrites, active = await streams.sourceActive(id)
        XCTAssertGreaterThan(lit, 0)
        XCTAssertTrue(active)
        try await streams.stopPattern(for: id)
        let failure = await streams.streamFailure(id), stillActive = await streams.sourceActive(id)
        XCTAssertNil(failure)
        XCTAssertFalse(stillActive)
        try await streams.disconnect(id)
    }

    func testAStreamWithNoRateIsRefused() async throws {
        let streams = LaserOutputStreams()
        let id = UUID()
        try await streams.connect(id) { StubSession(Recorder()) }
        let looper = LaserFrameLooper<LaserPoint>(format: LaserStreamFormat(domain: .scanner))
        struct Output: LaserOutputStream {
            let looper: LaserFrameLooper<LaserPoint>
            var format: LaserStreamFormat { looper.format }
            mutating func read(wanting count: Int) -> LaserChunk<LaserPoint> { looper.read(wanting: count) }
        }
        do { try await streams.play(stream: Output(looper: looper)); XCTFail("expected unsupportedPointRate") } catch {
            XCTAssertEqual(error as? LaserOutputError, .unsupportedPointRate)
        }
        try await streams.disconnect(id)
    }

    func testAnIdleStreamKeepsTheOutputDarkWithoutFailing() async throws {
        let recorder = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let id = UUID()
        try await streams.connect(id) { StubSession(recorder) }
        let looper = LaserFrameLooper<LaserPoint>(format: LaserStreamFormat(domain: .scanner, rate: 30000))   // nothing submitted
        struct Output: LaserOutputStream {
            let looper: LaserFrameLooper<LaserPoint>
            var format: LaserStreamFormat { looper.format }
            mutating func read(wanting count: Int) -> LaserChunk<LaserPoint> { looper.read(wanting: count) }
        }
        try await streams.play(stream: Output(looper: looper))
        try await Task.sleep(nanoseconds: 80_000_000)
        let lit = await recorder.litWrites, black = await recorder.blackWrites, failure = await streams.streamFailure(id)
        XCTAssertEqual(lit, 0)
        XCTAssertGreaterThan(black, 0)
        XCTAssertNil(failure)
        try await streams.disconnect(id)
    }
}
