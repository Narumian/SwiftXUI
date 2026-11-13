import Foundation
import simd
import XCTest
@testable import XLive

/// The promises of `ZoneOutputProtocol`, run against every kind that can be made. A new kind is not made the default
/// until it passes these.
final class ZoneOutputProtocolTests: XCTestCase {
    private actor Sink {
        var lit = 0, writes = 0, rates: [UInt32] = []
        func start(_ rate: UInt32) { rates.append(rate) }
        func write(_ points: [LaserPoint]) {
            writes += 1
            if points.contains(where: { !$0.isBlanked && $0.rgb != .zero }) { lit += 1 }
        }
    }

    private final class Session: LaserOutputSession, @unchecked Sendable {
        let sink: Sink
        let capabilities = LaserOutputCapabilities(maximumPointRate: 30000)
        let states = AsyncStream<LaserOutputState> { $0.finish() }
        init(_ sink: Sink) { self.sink = sink }
        func start(pointRate: UInt32) async throws { await sink.start(pointRate) }
        func write(_ points: [LaserPoint]) async throws { await sink.write(points) }
        func stop() async throws {}
        func disconnect() async throws {}
    }

    /// A zone that always shows one lit line, with frames of the length it is told.
    private struct LineZone: ZoneSource {
        let id: UUID
        let shapes = LaserLive(Laser3DBuffer())
        let mastering = LaserLive(LaserMastering())
        let maximumPointRate: UInt32 = 30000
        func renderNextFrame(afterSamples: Int, sampleRate: UInt32) async -> Laser3DBuffer {
            testBuffer([TestShape(id: 0, vertices: [LaserVertex(x: -0.5, y: 0), LaserVertex(x: 0.5, y: 0)])])
        }
    }

    private func delivery(_ zone: UUID) -> ZoneDelivery {
        var camera = matrix_identity_double4x4
        camera.columns.3 = SIMD4(0, 0, 2, 1)
        let projection = LaserProjection(camera: camera, projection: LaserProjection.perspective(fovxDegrees: 90, near: 0.1, far: 50))
        return ZoneDelivery(source: LineZone(id: zone), scanner: LaserLive(LaserScannerSettings()), projection: projection)
    }

    private func waitForLight(_ sink: Sink) async throws {
        for _ in 0..<400 where await sink.lit == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func made(_ kind: ZoneOutputKind, _ sinks: [UUID: Sink]) -> any ZoneOutputProtocol {
        kind.make(blockSize: 128, pauseMilliseconds: 2) { output in Session(sinks[output.id] ?? Sink()) }
    }

    func testAConnectedLaserReportsItselfAndADisconnectByHandReadsAsPaused() async throws {
        for kind in ZoneOutputKind.allCases {
            let laser = LaserOutput(name: "A", device: .laserCube)
            let output = made(kind, [laser.id: Sink()])
            var status = await output.status(of: laser.id)
            XCTAssertFalse(status.connected, "\(kind)"); XCTAssertFalse(status.playing, "\(kind)")
            try await output.connect(laser, automatic: false)
            status = await output.status(of: laser.id)
            XCTAssertTrue(status.connected, "\(kind)"); XCTAssertFalse(status.pausedByUser, "\(kind)")
            try await output.disconnect(laser.id)
            status = await output.status(of: laser.id)
            XCTAssertFalse(status.connected, "\(kind)"); XCTAssertTrue(status.pausedByUser, "\(kind)")
            await output.disconnectAll()
        }
    }

    func testAZoneRoutedToALaserLightsItUntilTheZoneStops() async throws {
        for kind in ZoneOutputKind.allCases {
            let laser = LaserOutput(name: "A", device: .laserCube), zone = UUID(), sink = Sink()
            let output = made(kind, [laser.id: sink])
            try await output.connect(laser, automatic: false)
            try await output.play(delivery(zone))
            await output.route(laser.id, to: zone)
            try await waitForLight(sink)
            let lit = await sink.lit
            XCTAssertGreaterThan(lit, 0, "\(kind): light reaches the laser")
            let status = await output.status(of: laser.id)
            XCTAssertTrue(status.playing, "\(kind)"); XCTAssertEqual(status.zone, zone, "\(kind)")
            XCTAssertNil(status.failure, "\(kind)")
            await output.stop(zone: zone)
            let stopped = await output.status(of: laser.id)
            XCTAssertFalse(stopped.playing, "\(kind): stopping the zone darkens its laser")
            await output.disconnectAll()
        }
    }

    func testALaserIsOnOneZoneAndRoutingItMovesIt() async throws {
        for kind in ZoneOutputKind.allCases {
            let laser = LaserOutput(name: "A", device: .laserCube), zoneA = UUID(), zoneB = UUID(), sink = Sink()
            let output = made(kind, [laser.id: sink])
            try await output.connect(laser, automatic: false)
            try await output.play(delivery(zoneA)); try await output.play(delivery(zoneB))
            await output.route(laser.id, to: zoneA)
            var status = await output.status(of: laser.id)
            XCTAssertEqual(status.zone, zoneA, "\(kind)")
            await output.route(laser.id, to: zoneB)
            status = await output.status(of: laser.id)
            XCTAssertEqual(status.zone, zoneB, "\(kind): one zone at a time")
            await output.route(laser.id, to: nil)
            status = await output.status(of: laser.id)
            XCTAssertNil(status.zone, "\(kind)"); XCTAssertFalse(status.playing, "\(kind)")
            await output.stop(zone: zoneA); await output.stop(zone: zoneB)
            await output.disconnectAll()
        }
    }

    func testTwoLasersOnTwoZonesAreDrivenApart() async throws {
        for kind in ZoneOutputKind.allCases {
            let a = LaserOutput(name: "A", device: .laserCube), b = LaserOutput(name: "B", device: .laserCube)
            let zoneA = UUID(), zoneB = UUID(), sinkA = Sink(), sinkB = Sink()
            let output = made(kind, [a.id: sinkA, b.id: sinkB])
            try await output.connect(a, automatic: false); try await output.connect(b, automatic: false)
            try await output.play(delivery(zoneA)); try await output.play(delivery(zoneB))
            await output.route(a.id, to: zoneA); await output.route(b.id, to: zoneB)
            try await waitForLight(sinkA); try await waitForLight(sinkB)
            await output.stop(zone: zoneA)
            let statusA = await output.status(of: a.id), statusB = await output.status(of: b.id)
            XCTAssertFalse(statusA.playing, "\(kind)")
            XCTAssertTrue(statusB.playing, "\(kind): stopping one zone leaves the other")
            await output.stop(zone: zoneB)
            await output.disconnectAll()
        }
    }

    func testPlayingAZoneAgainReplacesItAndKeepsItsLasersLit() async throws {
        for kind in ZoneOutputKind.allCases {
            let laser = LaserOutput(name: "A", device: .laserCube), zone = UUID(), sink = Sink()
            let output = made(kind, [laser.id: sink])
            try await output.connect(laser, automatic: false)
            await output.route(laser.id, to: zone)
            try await output.play(delivery(zone))
            try await waitForLight(sink)
            try await output.play(delivery(zone))
            let before = await sink.lit
            try await Task.sleep(nanoseconds: 100_000_000)
            let after = await sink.lit
            XCTAssertGreaterThan(after, before, "\(kind): still lit after the replacement")
            let status = await output.status(of: laser.id)
            XCTAssertTrue(status.playing, "\(kind)")
            await output.stop(zone: zone)
            await output.disconnectAll()
        }
    }

    func testTheReportNamesTheOutputsItDrives() async throws {
        for kind in ZoneOutputKind.allCases {
            let laser = LaserOutput(name: "A", device: .laserCube)
            let output = made(kind, [laser.id: Sink()])
            try await output.connect(laser, automatic: false)
            let report = await output.report()
            XCTAssertFalse(report.isEmpty, "\(kind)")
            await output.disconnectAll()
        }
    }
}

/// What only the `timeBase` kind promises: lasers of different rates and clocks play one zone together, and a laser that
/// stalls neither holds back the zone nor another laser. Devices here run on the real clock and hold a queue like a
/// credit-paced laser.
final class TimeBaseZoneOutputTests: XCTestCase {
    private final class QueueingDevice: LaserOutputQueueReporting, @unchecked Sendable {
        let capabilities: LaserOutputCapabilities
        let states = AsyncStream<LaserOutputState> { $0.finish() }
        private let lock = NSLock()
        private let rate: Double, skew: Double, target: Int
        private let started = HostZoneClock().now
        private var written = 0
        private var stalledUntil = 0.0
        private var lit = 0
        init(rate: UInt32, skewPPM: Double = 0) {
            capabilities = LaserOutputCapabilities(maximumPointRate: rate)
            self.rate = Double(rate); skew = skewPPM / 1e6; target = Int(Double(rate) * 0.2)
        }
        private func consumed(_ now: Double) -> Int { Swift.min(written, Int((now - started) * rate * (1 + skew))) }
        var queuedPoints: Int { lock.withLock { written - consumed(HostZoneClock().now) } }
        var queueCapacity: Int { target }
        var litWrites: Int { lock.withLock { lit } }
        private var lastBlock: [LaserPoint] = []
        /// The last block written.
        var lastWritten: [LaserPoint] { lock.withLock { lastBlock } }
        func stall(for seconds: Double) { lock.withLock { stalledUntil = HostZoneClock().now + seconds } }
        func start(pointRate: UInt32) async throws {}
        func write(_ points: [LaserPoint]) async throws {
            // A credit-paced write waits until the device has room, and a stalled link waits longer.
            while true {
                let wait: Bool = lock.withLock {
                    let now = HostZoneClock().now
                    return now < stalledUntil || written - consumed(now) >= target
                }
                if !wait { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            lock.withLock {
                written += points.count
                lastBlock = points
                if points.contains(where: { !$0.isBlanked && $0.rgb != .zero }) { lit += 1 }
            }
        }
        func stop() async throws {}
        func disconnect() async throws {}
    }

    private struct Line: ZoneSource {
        let id: UUID
        let shapes = LaserLive(Laser3DBuffer())
        let mastering = LaserLive(LaserMastering())
        let maximumPointRate: UInt32 = 50_000
        func renderNextFrame(afterSamples: Int, sampleRate: UInt32) async -> Laser3DBuffer {
            testBuffer([TestShape(id: 0, vertices: [LaserVertex(x: -0.5, y: 0), LaserVertex(x: 0.5, y: 0)])])
        }
    }

    private func delivery(_ zone: UUID) -> ZoneDelivery {
        var camera = matrix_identity_double4x4
        camera.columns.3 = SIMD4(0, 0, 2, 1)
        return ZoneDelivery(source: Line(id: zone), scanner: LaserLive(LaserScannerSettings()),
                            projection: LaserProjection(camera: camera, projection: LaserProjection.perspective(fovxDegrees: 90, near: 0.1, far: 50)))
    }

    func testLasersOfDifferentRatesAndClocksPlayOneZoneTogether() async throws {
        let a = LaserOutput(name: "30k", device: .laserCube), b = LaserOutput(name: "20k", device: .laserCube), c = LaserOutput(name: "30k+", device: .laserCube)
        let devices: [UUID: QueueingDevice] = [a.id: QueueingDevice(rate: 30_000), b.id: QueueingDevice(rate: 20_000), c.id: QueueingDevice(rate: 30_000, skewPPM: 300)]
        let output = TimeBaseZoneOutput { devices[$0.id]! }
        let zone = UUID()
        for laser in [a, b, c] { try await output.connect(laser, automatic: false); await output.route(laser.id, to: zone) }
        try await output.play(delivery(zone))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        var written: [UUID: Double] = [:]
        for laser in [a, b, c] {
            let status = await output.status(of: laser.id)
            XCTAssertTrue(status.playing, laser.name); XCTAssertNil(status.failure, laser.name)
            XCTAssertLessThan(abs(status.metrics["errorMs"] ?? 999), 30, "\(laser.name) is within 30 ms of the zone")
            XCTAssertEqual(status.metrics["jumps"], 0, laser.name)
            XCTAssertEqual(status.metrics["underrunSamples"], 0, laser.name)
            written[laser.id] = status.metrics["writtenSamples"]
            XCTAssertGreaterThan(devices[laser.id]!.litWrites, 0, laser.name)
        }
        // Each is given points at its own rate: 20k gets two thirds of what 30k does (plus the queue it holds).
        let ratio = (written[b.id] ?? 0) / (written[a.id] ?? 1)
        XCTAssertEqual(ratio, 2.0 / 3.0, accuracy: 0.12)
        await output.disablePreviews()
        await output.disconnectAll()
    }

    func testALaserThatStallsLongerThanItsQueueJumpsAloneAndTheOtherNeverNotices() async throws {
        let a = LaserOutput(name: "A", device: .laserCube), b = LaserOutput(name: "B", device: .laserCube)
        let devices: [UUID: QueueingDevice] = [a.id: QueueingDevice(rate: 30_000), b.id: QueueingDevice(rate: 20_000)]
        let output = TimeBaseZoneOutput { devices[$0.id]! }
        let zone = UUID()
        for laser in [a, b] { try await output.connect(laser, automatic: false); await output.route(laser.id, to: zone) }
        try await output.play(delivery(zone))
        try await Task.sleep(nanoseconds: 500_000_000)
        devices[b.id]!.stall(for: 0.6)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let statusA = await output.status(of: a.id), statusB = await output.status(of: b.id)
        XCTAssertEqual(statusA.metrics["jumps"], 0)
        XCTAssertEqual(statusA.metrics["underrunSamples"], 0)
        XCTAssertGreaterThanOrEqual(statusB.metrics["jumps"] ?? 0, 1, "B passed over what it missed")
        XCTAssertTrue(statusA.playing); XCTAssertTrue(statusB.playing); XCTAssertNil(statusB.failure)
        XCTAssertLessThan(abs(statusB.metrics["errorMs"] ?? 999), 30, "B is back in step")
        await output.disablePreviews()
        await output.disconnectAll()
    }

    func testAPreviewTakesTheLaserFromItsZoneAndEndingItGivesItBack() async throws {
        let laser = LaserOutput(name: "A", device: .laserCube)
        let device = QueueingDevice(rate: 30_000)
        let output = TimeBaseZoneOutput { _ in device }
        let zone = UUID()
        try await output.connect(laser, automatic: false); await output.route(laser.id, to: zone)
        try await output.play(delivery(zone))
        try await Task.sleep(nanoseconds: 200_000_000)
        try await output.setPreview(true, for: laser.id, masks: .init())
        var status = await output.status(of: laser.id)
        XCTAssertFalse(status.playing, "on the preview pattern it is off the zone")
        XCTAssertEqual(status.zone, zone, "but the route is kept")
        try await output.setPreview(false, for: laser.id, masks: .init())
        status = await output.status(of: laser.id)
        XCTAssertTrue(status.playing, "back on the zone")
        await output.disablePreviews()
        let dark = await output.status(of: laser.id)
        XCTAssertFalse(dark.playing, "disabling previews darkens every laser")
        await output.disconnectAll()
    }

    func testAShownPatternIsSentAsItIsAndLoopsUntilEnded() async throws {
        let laser = LaserOutput(name: "A", device: .laserCube)
        let device = QueueingDevice(rate: 30_000)
        let output = TimeBaseZoneOutput { _ in device }
        let zone = UUID()
        try await output.connect(laser, automatic: false); await output.route(laser.id, to: zone)
        try await output.play(delivery(zone))
        // 100 distinct points, fewer than a block, so a block of the output is a run of them, round and round.
        let pattern = try (0..<100).map { try LaserPoint(xy: SIMD2(Float($0) / 100 - 0.5, 0.25), rgb: SIMD3(repeating: 0.1), isBlanked: false) }
        try await output.showPattern(pattern, for: laser.id)
        try await Task.sleep(nanoseconds: 400_000_000)
        let block = device.lastWritten
        XCTAssertGreaterThan(block.count, 100, "more than one round of the pattern in a block")
        let start = try XCTUnwrap(pattern.firstIndex(of: block[0]))
        for (i, point) in block.enumerated() { XCTAssertEqual(point, pattern[(start + i) % pattern.count], "point \(i) unchanged and in order") }
        let status = await output.status(of: laser.id)
        XCTAssertFalse(status.playing, "off the zone while the pattern shows")
        try await output.setPreview(false, for: laser.id, masks: .init())
        let back = await output.status(of: laser.id)
        XCTAssertTrue(back.playing, "ending it gives the laser back to its zone")
        await output.disablePreviews()
        await output.disconnectAll()
    }

    func testAFailingDeviceIsReportedAndOthersKeepPlaying() async throws {
        struct Broken: Error {}
        final class BrokenSession: LaserOutputSession, @unchecked Sendable {
            let capabilities = LaserOutputCapabilities(maximumPointRate: 30_000)
            let states = AsyncStream<LaserOutputState> { $0.finish() }
            func start(pointRate: UInt32) async throws {}
            func write(_ points: [LaserPoint]) async throws { throw Broken() }
            func stop() async throws {}
            func disconnect() async throws {}
        }
        let bad = LaserOutput(name: "bad", device: .laserCube), good = LaserOutput(name: "good", device: .laserCube)
        let device = QueueingDevice(rate: 30_000)
        let output = TimeBaseZoneOutput { (laser: LaserOutput) -> any LaserOutputSession in
            if laser.id == bad.id { return BrokenSession() }
            return device
        }
        let zone = UUID()
        for laser in [bad, good] { try await output.connect(laser, automatic: false); await output.route(laser.id, to: zone) }
        try await output.play(delivery(zone))
        try await Task.sleep(nanoseconds: 300_000_000)
        let badStatus = await output.status(of: bad.id), goodStatus = await output.status(of: good.id)
        XCTAssertNotNil(badStatus.failure); XCTAssertFalse(badStatus.playing)
        XCTAssertNil(goodStatus.failure); XCTAssertTrue(goodStatus.playing)
        await output.disablePreviews()
        await output.disconnectAll()
    }
}
