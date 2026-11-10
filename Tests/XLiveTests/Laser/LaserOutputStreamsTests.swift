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

final class LaserZoneTests: XCTestCase, @unchecked Sendable {
    private func chunks(_ level: Float) -> AsyncStream<[LaserPoint]> {
        let lit = try! LaserPoint(xy: .zero, rgb: SIMD3<Float>(repeating: level))
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

    func testEachZonePlaysItsOwnSourceOnItsOwnOutputsOnly() async throws {
        let first = Recorder(), second = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let zoneA = UUID(), zoneB = UUID()
        let a = UUID(), b = UUID()
        try await streams.connect(a, zone: zoneA) { StubSession(first) }
        try await streams.connect(b, zone: zoneB) { StubSession(second) }
        try await streams.play(source: chunks(0.1), sampleRate: 30000, zone: zoneA)
        try await waitForLight(first)
        try await Task.sleep(nanoseconds: 60_000_000)
        let lightA = await first.glowWrites, lightB = await second.glowWrites
        let activeA = await streams.sourceActive(a), activeB = await streams.sourceActive(b)
        XCTAssertGreaterThan(lightA, 0)
        XCTAssertEqual(lightB, 0, "the other zone is not playing")
        XCTAssertTrue(activeA)
        XCTAssertFalse(activeB)
        try await streams.play(source: chunks(0.2), sampleRate: 30000, zone: zoneB)
        try await waitForLight(second)
        let afterB = await second.glowWrites, stillA = await streams.sourceActive(a)
        XCTAssertGreaterThan(afterB, 0)
        XCTAssertTrue(stillA, "playing a zone does not touch another")
        await streams.stopSource(zone: zoneA)
        let stoppedA = await streams.sourceActive(a), playingB = await streams.sourceActive(b)
        XCTAssertFalse(stoppedA)
        XCTAssertTrue(playingB)
        await streams.stopSource()
        try await streams.disconnect(a); try await streams.disconnect(b)
    }

    func testAnAssignmentMadeBeforeConnectingIsKeptForTheConnection() async throws {
        let recorder = Recorder()
        let connections = LaserOutputConnections(blockSize: 140, pauseMilliseconds: 1) { _ in StubSession(recorder) }
        let zone = UUID()
        let output = LaserOutput(name: "A")
        await connections.assign(output.id, to: zone)
        try await connections.connect(output)
        let streamZone = await connections.zoneOf(output.id)
        XCTAssertEqual(streamZone, zone)
        await connections.disconnectAll()
    }

    func testABoxOfShapesIsASourceThatAnswersWithWhatItHoldsNow() {
        let box = LaserLive(Laser3DBuffer())
        XCTAssertTrue(box.value.isEmpty)
        box.value = testBuffer([TestShape(id: 0, vertices: [LaserVertex(x: 0, y: 0, mode: .blank)])])
        XCTAssertEqual(box.value.shapeCount, 1)
        XCTAssertEqual(box.value.shapeCount, 1)
    }

    func testAnOutputAssignedToAPlayingZoneJoinsItAndLeavesItsOldOne() async throws {
        let first = Recorder(), moved = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let zoneA = UUID(), zoneB = UUID()
        let a = UUID(), b = UUID()
        try await streams.connect(a, zone: zoneA) { StubSession(first) }
        try await streams.connect(b, zone: zoneA) { StubSession(moved) }
        try await streams.play(source: chunks(0.1), sampleRate: 30000, zone: zoneA)
        try await streams.play(source: chunks(0.2), sampleRate: 30000, zone: zoneB)
        try await waitForLight(moved)
        await streams.assign(b, to: zoneB)
        let zone = await streams.zone(of: b), report = await streams.diagnosticsReport()
        XCTAssertEqual(zone, zoneB)
        XCTAssertTrue(report.contains("zone=\(zoneB)"), report)
        let before = await moved.glowWrites
        try await Task.sleep(nanoseconds: 100_000_000)
        let after = await moved.glowWrites
        XCTAssertGreaterThan(after, before, "it keeps playing, now from zone B")
        // Moving it to a zone that is not playing darkens it.
        await streams.assign(b, to: UUID())
        let active = await streams.sourceActive(b)
        XCTAssertFalse(active)
        await streams.stopSource()
        try await streams.disconnect(a); try await streams.disconnect(b)
    }

    func testAnOutputWithoutAZoneIsInTheDefaultZone() async throws {
        let recorder = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let id = UUID()
        try await streams.connect(id) { StubSession(recorder) }
        let zone = await streams.zone(of: id)
        XCTAssertEqual(zone, LaserOutputStreams.defaultZone)
        try await streams.play(source: chunks(0.1), sampleRate: 30000)
        try await waitForLight(recorder)
        let active = await streams.sourceActive(id)
        XCTAssertTrue(active)
        await streams.stopSource()
        try await streams.disconnect(id)
    }

    func testAZoneFailureIsReportedPerZone() async throws {
        struct Boom: Error {}
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let zoneA = UUID(), zoneB = UUID()
        let failing = AsyncThrowingStream<[LaserPoint], Error> { $0.finish(throwing: Boom()) }
        try await streams.play(source: failing, sampleRate: 30000, zone: zoneA)
        try await streams.play(source: chunks(0.1), sampleRate: 30000, zone: zoneB)
        try await Task.sleep(nanoseconds: 50_000_000)
        let failureA = await streams.sourceFailure(zone: zoneA), failureB = await streams.sourceFailure(zone: zoneB)
        XCTAssertNotNil(failureA)
        XCTAssertNil(failureB)
        await streams.stopSource()
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

    func testAScannerChainPlaysOnAnOutputAndStopsCleanly() async throws {
        let recorder = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let id = UUID()
        try await streams.connect(id) { StubSession(recorder) }
        let looper = FixedFrame([TestShape(id: 1, vertices: [LaserVertex(x: 0.4, y: 0), LaserVertex(x: -0.4, y: 0)])])
        let chain = LaserScannerChain(looper, projection: projection(), live: LaserLive(LaserScannerSettings(maximumStep: 0.05)), rate: 30000)
        try await streams.play(stream: chain)
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
        do { try await streams.play(stream: IdleOutput(rate: nil)); XCTFail("expected unsupportedPointRate") } catch {
            XCTAssertEqual(error as? LaserOutputError, .unsupportedPointRate)
        }
        try await streams.disconnect(id)
    }

    func testAnIdleStreamKeepsTheOutputDarkWithoutFailing() async throws {
        let recorder = Recorder()
        let streams = LaserOutputStreams(blockSize: 140, pauseMilliseconds: 1)
        let id = UUID()
        try await streams.connect(id) { StubSession(recorder) }
        try await streams.play(stream: IdleOutput(rate: 30000))   // nothing to play
        try await Task.sleep(nanoseconds: 80_000_000)
        let lit = await recorder.litWrites, black = await recorder.blackWrites, failure = await streams.streamFailure(id)
        XCTAssertEqual(lit, 0)
        XCTAssertGreaterThan(black, 0)
        XCTAssertNil(failure)
        try await streams.disconnect(id)
    }
}

/// A scanner stream with nothing to play.
private struct IdleOutput: Laser2DStream {
    var rate: UInt32?
    mutating func read() -> [Laser2DShape] { [] }
}
