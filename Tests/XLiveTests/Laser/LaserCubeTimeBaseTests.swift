import Foundation
import simd
import XCTest
@testable import XLive

/// A cube simulated in software that drains its buffer by the clock, so the real session code (credit pacing, queue
/// reporting) runs against something that behaves like a device. No hardware is involved.
private final class DrainingCube: LaserCubeTransport, @unchecked Sendable {
    static let size = 10000
    private let lock = NSLock()
    private let host = HostZoneClock()
    private var rate: UInt32 = 30000
    private let skew: Double
    private var output = false
    private var closed = false
    private var queued = 0.0
    private var at: Double
    private(set) var runDry = 0
    private(set) var sampleCount = 0
    private var stalledUntil = 0.0

    init(skewPPM: Double = 0) { skew = skewPPM / 1e6; at = host.now }

    /// Brings the queue up to date; the cube plays what it holds while its output is on.
    private func settle() {
        let now = host.now
        if output {
            let played = (now - at) * Double(rate) * (1 + skew)
            if played > queued { if queued > 0 || played > 0 { runDry += queued < played - 1 ? 1 : 0 }; queued = 0 } else { queued -= played }
        }
        at = now
    }

    var queuedNow: Int { lock.withLock { settle(); return Int(queued) } }
    func stall(for seconds: Double) { lock.withLock { stalledUntil = host.now + seconds } }

    func exchange(_ message: Data, on channel: LaserCubeChannel, timeout: Duration) async throws -> Data {
        try Task.checkCancellation()
        if case .data = channel {
            while lock.withLock({ host.now < stalledUntil }) { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        return try lock.withLock {
            guard !closed else { throw LaserOutputError.disconnected }
            settle()
            let free = Self.size - Int(queued)
            switch message[0] {
            case 0x77: return Data(Self.info(rate: rate, free: free, enabled: output))
            case 0x80: output = message[1] != 0
            case 0x8d: queued = 0
            case 0x82: rate = UInt32(message[1]) | UInt32(message[2]) << 8 | UInt32(message[3]) << 16 | UInt32(message[4]) << 24
            case 0x8a: return Data([0x8a, 0, UInt8(truncatingIfNeeded: free), UInt8(truncatingIfNeeded: free >> 8)])
            case 0xa9:
                let count = (message.count - 4) / 10
                guard count <= free else { throw LaserCubeError.malformedResponse }
                output = true
                queued += Double(count); sampleCount += count
                let left = Self.size - Int(queued)
                return Data([0x8a, message[2], UInt8(truncatingIfNeeded: left), UInt8(truncatingIfNeeded: left >> 8)])
            default: break
            }
            return Data([message[0], 0])
        }
    }
    func close() { lock.withLock { closed = true } }

    static func info(rate: UInt32, free: Int, enabled: Bool) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x77; bytes[3] = 1; bytes[4] = 30
        bytes[5] = enabled ? 1 : 0
        for i in 0..<4 {
            bytes[10 + i] = UInt8(truncatingIfNeeded: rate >> (i * 8))
            bytes[14 + i] = UInt8(truncatingIfNeeded: UInt32(35000) >> (i * 8))
        }
        bytes[19] = UInt8(truncatingIfNeeded: free); bytes[20] = UInt8(truncatingIfNeeded: free >> 8)
        bytes[21] = UInt8(truncatingIfNeeded: size); bytes[22] = UInt8(truncatingIfNeeded: size >> 8)
        return bytes
    }
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

final class LaserCubeTimeBaseTests: XCTestCase {
    func testTheSessionReportsItsQueueAndHowDeepItIsKept() async throws {
        let cube = DrainingCube()
        let session = try await LaserCube(id: "sim") { cube }.connect()
        let reporting = try XCTUnwrap(session as? any LaserOutputQueueReporting, "a LaserCube session reports its queue")
        XCTAssertEqual(reporting.queueCapacity, DrainingCube.size - 140)
        try await session.start(pointRate: 30000)
        let before = await reporting.queuedPoints
        XCTAssertEqual(before, 0)
        let point = try LaserPoint(xy: .zero, rgb: [0.1, 0.1, 0.1])
        try await session.write(Array(repeating: point, count: 3000))
        let queued = await reporting.queuedPoints
        XCTAssertGreaterThan(queued, 2000); XCTAssertLessThanOrEqual(queued, 3000)
        // It runs down with the clock between the device's replies (the monitor looks every 25 ms).
        try await Task.sleep(nanoseconds: 60_000_000)
        let later = await reporting.queuedPoints
        XCTAssertLessThan(later, queued)
        XCTAssertEqual(abs(Double(later) - Double(cube.queuedNow)) / 30000 < 0.03, true, "the estimate is within 30 ms of the device")
        try await session.disconnect()
    }

    func testTimeBaseDrivesAFillingCubeWithoutRunningItDry() async throws {
        // The cube keeps ~0.33 s queued, longer than the default horizon: the zone is made ahead by that much.
        let cube = DrainingCube(skewPPM: 200)
        let laser = LaserOutput(name: "Cube", device: .laserCube)
        let output = TimeBaseZoneOutput { _ in try await LaserCube(id: "sim") { cube }.connect() }
        let zone = UUID()
        try await output.connect(laser, automatic: false)
        await output.route(laser.id, to: zone)
        try await output.play(delivery(zone))
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let status = await output.status(of: laser.id)
        XCTAssertTrue(status.playing); XCTAssertNil(status.failure)
        XCTAssertLessThan(status.metrics["underrunSamples"] ?? 999999, 3000, "the lane may run out of zone only for a moment at the start")
        XCTAssertEqual(status.metrics["jumps"], 0)
        XCTAssertLessThan(abs(status.metrics["errorMs"] ?? 999), 30)
        XCTAssertEqual(cube.runDry, 0, "the cube never ran dry")
        XCTAssertGreaterThan(cube.queuedNow, 5000, "it is kept well filled")
        await output.disablePreviews()
        await output.disconnectAll()
    }

    func testAnOutageOfAFewTenthsOfASecondIsAbsorbedByTheQueueAndALongOneIsJumped() async throws {
        let cube = DrainingCube()
        let laser = LaserOutput(name: "Cube", device: .laserCube)
        let output = TimeBaseZoneOutput { _ in try await LaserCube(id: "sim") { cube }.connect() }
        let zone = UUID()
        try await output.connect(laser, automatic: false)
        await output.route(laser.id, to: zone)
        try await output.play(delivery(zone))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        cube.stall(for: 0.15)   // longer than the Wi-Fi's 90 ms, shorter than the queue
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var status = await output.status(of: laser.id)
        XCTAssertEqual(status.metrics["jumps"], 0, "absorbed")
        XCTAssertEqual(cube.runDry, 0)
        cube.stall(for: 0.9)    // longer than the queue
        try await Task.sleep(nanoseconds: 2_500_000_000)
        status = await output.status(of: laser.id)
        XCTAssertGreaterThanOrEqual(status.metrics["jumps"] ?? 0, 1, "jumped over what the cube missed")
        XCTAssertLessThan(abs(status.metrics["errorMs"] ?? 999), 30, "back in step")
        XCTAssertNil(status.failure)
        await output.disablePreviews()
        await output.disconnectAll()
    }
}
