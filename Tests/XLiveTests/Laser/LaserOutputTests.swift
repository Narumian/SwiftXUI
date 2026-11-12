import Foundation
import XCTest
@testable import XLive

private actor ConnectionRecorder {
    var connected: [UUID] = []
    var stopped = 0
    func add(_ id: UUID) { connected.append(id) }
    func stop() { stopped += 1 }
}

private final class RecordingSession: LaserOutputSession, @unchecked Sendable {
    let recorder: ConnectionRecorder
    let capabilities = LaserOutputCapabilities(maximumPointRate: 30000)
    let states = AsyncStream<LaserOutputState> { $0.finish() }
    init(_ recorder: ConnectionRecorder) { self.recorder = recorder }
    func start(pointRate: UInt32) async throws {}
    func write(_ points: [LaserPoint]) async throws {}
    func stop() async throws {}
    func disconnect() async throws { await recorder.stop() }
}

/// Models the DAC buffer of a real device: it drains at the point rate and the
/// session underruns when it runs empty, as LaserCube does.
private final class DrainingSession: LaserOutputSession, @unchecked Sendable {
    let capabilities = LaserOutputCapabilities(maximumPointRate: 30000)
    let states = AsyncStream<LaserOutputState> { $0.finish() }
    private let lock = NSLock()
    private var queued = 0.0
    private var last = Date()
    private var primed = false
    private var underrun = false
    private let capacity = 5860.0
    func start(pointRate: UInt32) async throws { lock.withLock { queued = 0; last = Date(); primed = false } }
    func stop() async throws {}
    func disconnect() async throws {}
    private func level() -> Double {
        let now = Date()
        queued = max(0, queued - now.timeIntervalSince(last) * 30000)
        last = now
        if primed && queued == 0 { underrun = true }
        return queued
    }
    func write(_ points: [LaserPoint]) async throws {
        while true {
            let ok: Bool? = lock.withLock {
                if level() + Double(points.count) <= capacity { queued += Double(points.count); primed = true; return true }
                return underrun ? nil : false
            }
            if ok == nil { throw LaserCubeError.underrun }
            if ok == true { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
    var didUnderrun: Bool { lock.withLock { _ = level(); return underrun } }
}

final class LaserOutputTests: XCTestCase, @unchecked Sendable {
    func testMaskAttenuatesInsideAndSoftensAtEdge() {
        var polygon = LaserMask.make(.polygon)
        XCTAssertEqual(polygon.multiplier(at: .init(0.5, 0.5)), 0)
        XCTAssertEqual(polygon.multiplier(at: .init(0.1, 0.5)), 1)
        polygon.softEdge = 0.1
        polygon.dimmer = 0.2
        XCTAssertEqual(polygon.multiplier(at: .init(0.25, 0.5)), 0.6, accuracy: 0.00001)
        let ellipse = LaserMask.make(.ellipse)
        XCTAssertEqual(ellipse.multiplier(at: .init(0.5, 0.5)), 0)
        XCTAssertEqual(ellipse.multiplier(at: .init(0.1, 0.1)), 1)
        XCTAssertEqual(LaserMaskSettings(masks: [polygon, ellipse]).multiplier(at: .init(0.5, 0.5)), 0)
    }

    func testOutputSettingsPersistIndependentlyAndMigrateLegacyMasks() throws {
        let suite = "xlive.output.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = LaserMaskSettings(masks: [.make(.ellipse)])
        defaults.set(try JSONEncoder().encode(legacy), forKey: "trident.laser.masks.default")
        var collection = LaserOutputStorage.load(defaults: defaults)
        XCTAssertEqual(collection.outputs.count, 1)
        XCTAssertEqual(collection.outputs[0].masks, legacy)
        let first = collection.outputs[0].id
        collection.outputs.append(LaserOutput(name: "Second", device: .laserCube, address: "192.168.1.106"))
        let second = collection.outputs[1].id
        collection.updateMasks(.init(masks: [.make(.polygon)]), for: second)
        try LaserOutputStorage.save(collection, defaults: defaults)
        let reloaded = LaserOutputStorage.load(defaults: defaults)
        XCTAssertEqual(reloaded.outputs.first { $0.id == first }?.masks, legacy)
        XCTAssertEqual(reloaded.outputs.first { $0.id == second }?.masks.masks.first?.shape, .polygon)
        XCTAssertEqual(reloaded.outputs.first { $0.id == second }?.address, "192.168.1.106")
    }

    func testOutputRejectsInvalidIPv4() {
        XCTAssertTrue(LaserOutput.isValidIPv4("192.168.1.106"))
        for value in ["", "192.168.1", "192.168.1.256", "192.168..1", "-1.0.0.1", "１２７.0.0.1"] {
            XCTAssertFalse(LaserOutput.isValidIPv4(value), value)
        }
    }

    func testConnectionsAreIndependentByOutputID() async throws {
        let recorder = ConnectionRecorder()
        let manager = LaserOutputConnections { output in await recorder.add(output.id); return RecordingSession(recorder) }
        let first = LaserOutput(name: "One"), second = LaserOutput(name: "Two")
        try await manager.connect(first)
        try await manager.connect(second)
        let firstConnected = await manager.hasSession(first.id)
        XCTAssertTrue(firstConnected)
        try await manager.disconnect(first.id)
        let firstGone = await manager.hasSession(first.id), secondKept = await manager.hasSession(second.id)
        XCTAssertFalse(firstGone)
        XCTAssertTrue(secondKept)
        let connected = await recorder.connected, stoppedOnce = await recorder.stopped
        XCTAssertEqual(connected, [first.id, second.id])
        XCTAssertEqual(stoppedOnce, 1)
        try await manager.disconnect(second.id)
        let stoppedTwice = await recorder.stopped
        XCTAssertEqual(stoppedTwice, 2)
    }

    func testRapidMaskEditsDoNotStarveTheStream() async throws {
        let session = DrainingSession()
        let manager = LaserOutputConnections { _ in session }
        let output = LaserOutput(name: "One")
        try await manager.connect(output)
        var mask = LaserMask.make(.polygon); mask.softEdge = 0.5
        var settings = LaserMaskSettings(masks: [mask, .make(.ellipse)])
        try await manager.setPreview(true, for: output.id, masks: settings)
        // A handle drag produces input far faster than the output needs masks.
        let end = Date().addingTimeInterval(2)
        var i = 0
        while Date() < end {
            settings.masks[0].dimmer = Double(i % 100) / 100
            // The editor fires one detached task per pointer event, without awaiting it.
            let snapshot = settings
            Task { await manager.updatePreviewMasks(snapshot, for: output.id) }
            i += 1
            if i % 4 == 0 { try await Task.sleep(nanoseconds: 8_000_000) }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let failure = await manager.streamFailure(output.id), enabled = await manager.previewEnabled(output.id)
        XCTAssertNil(failure)
        XCTAssertFalse(session.didUnderrun)
        XCTAssertTrue(enabled)
        try await manager.disconnect(output.id)
    }
}
