import Foundation
import XCTest
@testable import XLive

final class LaserCubeTests: XCTestCase, @unchecked Sendable {
    func testWireLayoutAndBlanking() throws {
        let points = [try LaserPoint(xy: [-1, 1], rgb: [1, 0.5, 0]),
                      try LaserPoint(xy: [1, -1], rgb: [1, 1, 1], isBlanked: true)]
        let data = LaserCubeWire.samples(points[...], sequence: 255, frame: 7)
        XCTAssertEqual(Array(data), [0xa9, 0, 255, 7,
                                    255, 15, 255, 15, 255, 15, 255, 7, 0, 0,
                                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(LaserCubeWire.rate(35000), Data([0x82, 0xb8, 0x88, 0, 0]))
    }

    func testFullInfoUsesVersionByteAndFirmwareDependentFlags() throws {
        var bytes = ScriptedCube.infoBytes(rate: 30000, free: 8000, enabled: true)
        bytes[3] = 0; bytes[4] = 12; bytes[5] = 1 | 8
        let legacy = try LaserCubeWire.info(Data(bytes))
        XCTAssertTrue(legacy.outputEnabled)
        XCTAssertFalse(legacy.overTemperature) // old bit 3 is interlock, not temperature
        bytes[4] = 13
        XCTAssertTrue(try LaserCubeWire.info(Data(bytes)).overTemperature)
        bytes[2] = 1
        XCTAssertThrowsError(try LaserCubeWire.info(Data(bytes))) {
            XCTAssertEqual($0 as? LaserCubeError, .unsupportedProtocol(1))
        }
        XCTAssertThrowsError(try LaserCubeWire.info(Data(bytes.dropLast())))
        XCTAssertThrowsError(try LaserCubeWire.bufferFree(Data([0x8a, 0, 0xff, 0xff]), capacity: 10000))
        XCTAssertThrowsError(try LaserCubeWire.bufferFree(Data([0x8a, 1, 0, 0]), capacity: 10000))
        XCTAssertEqual(try LaserCubeWire.bufferFree(Data([0x8a, 37, 0x70, 0x17]), capacity: 6000, sequence: 37), 6000)
        XCTAssertThrowsError(try LaserCubeWire.bufferFree(Data([0x8a, 36, 0, 0]), capacity: 6000, sequence: 37))
    }

    func testConnectDisablesAndClearsBeforeReadyAndStartVerifiesRate() async throws {
        let transport = ScriptedCube()
        let device = LaserCube(id: "test") { transport }
        let session = try await device.connect()
        XCTAssertEqual(transport.messages.map { $0[0] }, [0x77, 0x80, 0x8d, 0x77])
        XCTAssertEqual(session.capabilities.maximumPointRate, 35000)
        var events = session.states.makeAsyncIterator()
        let ready = await events.next()
        XCTAssertEqual(ready, .ready)
        try await session.start(pointRate: 30000)
        let running = await events.next()
        XCTAssertEqual(running, .running(pointRate: 30000))
        XCTAssertFalse(transport.enabled) // No sample writes yet.
        try await session.disconnect()
        XCTAssertTrue(transport.isClosed)
    }

    func testFirstBlockBeginsPlaybackAndSendsShortTailWithoutPadding() async throws {
        let transport = ScriptedCube()
        let session = try await LaserCube(id: "test") { transport }.connect()
        try await session.start(pointRate: 30000)
        let point = try LaserPoint(xy: .zero, rgb: [0.1, 0.1, 0.1])
        try await session.write(Array(repeating: point, count: 141))
        XCTAssertEqual(transport.packets.map(\.count), [1404, 14])
        XCTAssertTrue(transport.enabled) // Real firmware auto-enables on sample data.
        try await session.write(Array(repeating: point, count: 2859))
        XCTAssertTrue(transport.enabled)
        XCTAssertEqual(transport.packets.reduce(0) { $0 + ($1.count - 4) / 10 }, 3000)
        try await session.stop()
        XCTAssertFalse(transport.enabled)
        XCTAssertEqual(transport.bufferFree, 10000)
        try await session.disconnect()
    }

    func testPacketSequenceIncludes255AndWrapsWithoutDuplicateSends() async throws {
        let transport = ScriptedCube()
        let session = try await LaserCube(id: "test") { transport }.connect()
        try await session.start(pointRate: 35000)
        let point = try LaserPoint(xy: .zero, rgb: .zero, isBlanked: true)
        try await session.write(Array(repeating: point, count: 140 * 258))
        let packets = transport.packets
        XCTAssertEqual(packets.count, 258)
        XCTAssertEqual(packets[254][2], 254)
        XCTAssertEqual(packets[255][2], 255)
        XCTAssertEqual(packets[256][2], 0)
        XCTAssertEqual(packets[257][2], 1)
        XCTAssertNotEqual(packets[0][3], packets[256][3])
        try await session.disconnect()
    }

    func testStopInterruptsBlockedWriteAndAllowsNewTimeline() async throws {
        let began = expectation(description: "data send suspended")
        let transport = ScriptedCube(onBlockedData: { began.fulfill() })
        let session = try await LaserCube(id: "test") { transport }.connect()
        try await session.start(pointRate: 30000)
        transport.blockData = true
        let point = try LaserPoint(xy: .zero, rgb: .zero)
        let writer = Task { try await session.write([point]) }
        await fulfillment(of: [began], timeout: 2)
        try await session.stop()
        do { try await writer.value; XCTFail("write should be interrupted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(transport.enabled)
        XCTAssertFalse(transport.isClosed)
        transport.blockData = false
        try await session.start(pointRate: 25000)
        try await session.write([point])
        try await session.disconnect()
    }

    func testProducerCancellationStillSendsOutputOffAndCloses() async throws {
        let began = expectation(description: "data send suspended")
        let transport = ScriptedCube(onBlockedData: { began.fulfill() })
        let session = try await LaserCube(id: "test") { transport }.connect()
        try await session.start(pointRate: 30000)
        transport.blockData = true
        let point = try LaserPoint(xy: .zero, rgb: .zero)
        let writer = Task { try await session.write([point]) }
        await fulfillment(of: [began], timeout: 2)
        writer.cancel()
        do { try await writer.value; XCTFail("write should be cancelled") } catch {}
        XCTAssertEqual(Array(transport.messages.suffix(2)), [Data([0x80, 0]), Data([0x8d])])
        XCTAssertTrue(transport.isClosed)
        try await session.disconnect()
    }

    func testUnappliedRateFailsWithoutEnablingLight() async throws {
        let transport = ScriptedCube(applyRate: false)
        let session = try await LaserCube(id: "test") { transport }.connect()
        do { try await session.start(pointRate: 25000); XCTFail("must verify device rate") }
        catch { XCTAssertEqual(error as? LaserCubeError, .configurationNotApplied) }
        XCTAssertFalse(transport.enabled)
        XCTAssertTrue(transport.isClosed)
        try await session.disconnect()
    }

    func testUnderrunIsToleratedAndStreamingResumes() async throws {
        let transport = ScriptedCube()
        let session = try await LaserCube(id: "test") { transport }.connect()
        try await session.start(pointRate: 30000)
        let point = try LaserPoint(xy: .zero, rgb: .zero)
        try await session.write(Array(repeating: point, count: 3000))
        let observer = Task {
            for await state in session.states {
                if case .failed(let message) = state { XCTFail("an underrun must not end the session: \(message)") }
            }
        }
        transport.emptyBuffer()
        // The monitor polls every 25 ms: give it several looks at the empty buffer.
        try await Task.sleep(for: .milliseconds(200))
        try await session.write(Array(repeating: point, count: 3000))
        XCTAssertTrue(transport.enabled)
        try await session.disconnect()
        observer.cancel()
        XCTAssertFalse(transport.enabled)
        XCTAssertTrue(transport.isClosed)
    }
}

private final class ScriptedCube: LaserCubeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Data] = []
    private var output = true
    private var free = 10000
    private var rate: UInt32 = 30000
    private var closed = false
    private var blocked = false
    private let applyRate: Bool
    private let onBlockedData: @Sendable () -> Void

    init(applyRate: Bool = true, onBlockedData: @escaping @Sendable () -> Void = {}) {
        self.applyRate = applyRate; self.onBlockedData = onBlockedData
    }
    var messages: [Data] { lock.withLock { recorded } }
    var packets: [Data] { messages.filter { $0.first == 0xa9 } }
    var enabled: Bool { lock.withLock { output } }
    var isClosed: Bool { lock.withLock { closed } }
    var bufferFree: Int { lock.withLock { free } }
    var blockData: Bool {
        get { lock.withLock { blocked } }
        set { lock.withLock { blocked = newValue } }
    }
    func emptyBuffer() { lock.withLock { free = 10000 } }

    func exchange(_ message: Data, on channel: LaserCubeChannel, timeout: Duration) async throws -> Data {
        try Task.checkCancellation()
        if case .data = channel, blockData {
            onBlockedData()
            try await Task.sleep(for: .seconds(30))
        }
        return try lock.withLock {
            guard !closed else { throw LaserOutputError.disconnected }
            recorded.append(message)
            switch message[0] {
            case 0x77: return Data(Self.infoBytes(rate: rate, free: free, enabled: output))
            case 0x80: output = message[1] != 0
            case 0x8d: free = 10000
            case 0x82:
                if applyRate {
                    rate = UInt32(message[1]) | UInt32(message[2]) << 8 | UInt32(message[3]) << 16 | UInt32(message[4]) << 24
                }
            case 0x8a:
                if output { free = min(9999, free + 140) }
                return bufferReply()
            case 0xa9:
                let count = (message.count - 4) / 10
                if output { free = min(9999, free + count) }
                output = true
                guard count <= free else { throw LaserCubeError.malformedResponse }
                free -= count
                return bufferReply(sequence: message[2])
            default: break
            }
            return Data([message[0], 0])
        }
    }

    private func bufferReply(sequence: UInt8 = 0) -> Data {
        Data([0x8a, sequence, UInt8(truncatingIfNeeded: free), UInt8(truncatingIfNeeded: free >> 8)])
    }
    func close() { lock.withLock { closed = true } }

    static func infoBytes(rate: UInt32, free: Int, enabled: Bool) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x77; bytes[2] = 0; bytes[3] = 1; bytes[4] = 30
        bytes[5] = enabled ? 1 : 0
        for i in 0..<4 {
            bytes[10 + i] = UInt8(truncatingIfNeeded: rate >> (i * 8))
            bytes[14 + i] = UInt8(truncatingIfNeeded: UInt32(35000) >> (i * 8))
        }
        bytes[19] = UInt8(truncatingIfNeeded: free); bytes[20] = UInt8(truncatingIfNeeded: free >> 8)
        bytes[21] = 0x10; bytes[22] = 0x27
        return bytes
    }
}
