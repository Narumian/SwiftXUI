#if canImport(Network)
import Foundation
import Network
import XCTest
import XLive
@testable import XLiveApple

final class AppleLaserCubeTransportTests: XCTestCase, @unchecked Sendable {
    func testIndependentPeersAndImmediateReconnectWithEphemeralPorts() async throws {
        let first = try LocalCubePeer(tag: 2, injectStaleFeedback: true)
        let second = try LocalCubePeer(tag: 3)
        defer { first.close(); second.close() }
        await fulfillment(of: [first.ready, second.ready], timeout: 3)
        let a = try AppleLaserCubeTransport(host: "127.0.0.1", commandPort: first.commandPort, dataPort: first.dataPort)
        let b = try AppleLaserCubeTransport(host: "127.0.0.1", commandPort: second.commandPort, dataPort: second.dataPort)
        defer { a.close(); b.close() }
        XCTAssertThrowsError(try AppleLaserCubeTransport(host: "127.0.0.1", commandPort: first.commandPort, dataPort: first.dataPort)) {
            XCTAssertEqual($0 as? AppleLaserCubeError, .endpointInUse)
        }
        async let responseA = a.exchange(Data([0x77]), on: .command, timeout: .seconds(2))
        async let responseB = b.exchange(Data([0x77]), on: .command, timeout: .seconds(2))
        let replies = try await (responseA, responseB)
        XCTAssertEqual(replies.0, Data([0x77, 0, 2]))
        XCTAssertEqual(replies.1, Data([0x77, 0, 3]))
        let dataReply = try await a.exchange(Data([0xa9, 0, 37, 0]), on: .data, timeout: .seconds(2))
        XCTAssertEqual(dataReply, Data([0x8a, 37, 2, 0]))
        a.close()
        let replacement = try AppleLaserCubeTransport(host: "127.0.0.1", commandPort: first.commandPort, dataPort: first.dataPort)
        defer { replacement.close() }
        let reconnected = try await replacement.exchange(Data([0x77]), on: .command, timeout: .seconds(2))
        XCTAssertEqual(reconnected, Data([0x77, 0, 2]))
    }

    func testTimeoutCancellationAndCloseReleasePendingReceives() async throws {
        let peer = try LocalCubePeer(tag: 4, silent: true)
        defer { peer.close() }
        await fulfillment(of: [peer.ready], timeout: 3)
        let transport = try AppleLaserCubeTransport(host: "127.0.0.1", commandPort: peer.commandPort, dataPort: peer.dataPort)
        defer { transport.close() }
        do {
            _ = try await transport.exchange(Data([0x77]), on: .command, timeout: .milliseconds(50))
            XCTFail("must time out")
        } catch { XCTAssertEqual(error as? LaserCubeError, .timeout) }
        let request = Task { try await transport.exchange(Data([0x77]), on: .command, timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(20))
        request.cancel()
        do { _ = try await request.value; XCTFail("must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        let packets = (0..<20).map { Data([0xa9, 0, UInt8($0), 0]) }
        let pending = Task { try await transport.exchangeSamples(packets, timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(20))
        transport.close()
        do { _ = try await pending.value; XCTFail("close must interrupt receive") }
        catch { XCTAssertEqual(error as? LaserOutputError, .disconnected) }
    }

    func testTwentyPacketsAreSentInOrderBeforeFeedbackAndRepliesAreReordered() async throws {
        let peer = try LocalCubePeer(tag: 9, feedbackBatchCount: 20)
        defer { peer.close() }
        await fulfillment(of: [peer.ready], timeout: 3)
        let transport = try AppleLaserCubeTransport(host: "127.0.0.1", commandPort: peer.commandPort, dataPort: peer.dataPort)
        defer { transport.close() }
        let sequences = (240..<260).map { UInt8(truncatingIfNeeded: $0) }
        let packets = sequences.map { Data([0xa9, 0, $0, 0]) }
        let replies = try await transport.exchangeSamples(packets, timeout: .seconds(2))
        XCTAssertEqual(peer.sampleSequences, sequences)
        XCTAssertEqual(replies.map { $0[1] }, sequences)
        XCTAssertTrue(replies.allSatisfy { $0.count == 4 && $0[2] == 9 })
    }

    func testDuplicatedSamplePacketsAreSentTwiceAndExtraRepliesAreIgnored() async throws {
        // The peer acknowledges every datagram, as a device that does not collapse
        // the repeat would: the surplus replies must not satisfy another exchange.
        let peer = try LocalCubePeer(tag: 7)
        defer { peer.close() }
        await fulfillment(of: [peer.ready], timeout: 3)
        let transport = try AppleLaserCubeTransport(host: "127.0.0.1", commandPort: peer.commandPort,
                                                    dataPort: peer.dataPort, duplicatesSamplePackets: true)
        defer { transport.close() }
        let sequences: [UInt8] = [10, 11, 12]
        let replies = try await transport.exchangeSamples(sequences.map { Data([0xa9, 0, $0, 0]) }, timeout: .seconds(2))
        XCTAssertEqual(replies.map { $0[1] }, sequences)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(peer.sampleSequences.sorted(), [10, 10, 11, 11, 12, 12])
        // Commands are never repeated.
        let info = try await transport.exchange(Data([0x77]), on: .command, timeout: .seconds(1))
        XCTAssertEqual(info, Data([0x77, 0, 7]))
        let next = try await transport.exchangeSamples([Data([0xa9, 0, 13, 0])], timeout: .seconds(2))
        XCTAssertEqual(next.map { $0[1] }, [13])
    }

    func testRejectsBroadcastMulticastAndHostnameAddresses() {
        for address in ["255.255.255.255", "224.0.0.1", "0.0.0.0", "localhost", "not-an-address"] {
            XCTAssertThrowsError(try AppleLaserCubeTransport(host: address)) {
                XCTAssertEqual($0 as? AppleLaserCubeError, .invalidIPv4Address)
            }
        }
    }
}

/// Loopback-only protocol fixture. Never discovers or contacts physical devices.
private final class LocalCubePeer: @unchecked Sendable {
    let ready = XCTestExpectation(description: "loopback UDP peer ready")
    private let queue = DispatchQueue(label: "LaserCubeTests.UDP")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let listeners: [NWListener]
    private var connections: [NWConnection] = []
    private var closed = false
    private var receivedSequences: [UInt8] = []
    private var waitingFeedback: [(NWConnection, UInt8)] = []

    var commandPort: UInt16 { queue.sync { listeners[0].port!.rawValue } }
    var dataPort: UInt16 { queue.sync { listeners[1].port!.rawValue } }
    var sampleSequences: [UInt8] { queue.sync { receivedSequences } }

    init(tag: UInt8, silent: Bool = false, injectStaleFeedback: Bool = false, feedbackBatchCount: Int = 1) throws {
        ready.expectedFulfillmentCount = 2
        listeners = try (0..<2).map { _ in
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            return try NWListener(using: parameters)
        }
        queue.setSpecific(key: queueKey, value: true)
        for listener in listeners {
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.ready.fulfill()
                case .failed(let error): XCTFail("loopback listener failed: \(error)"); self?.ready.fulfill()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.closed else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, tag: tag, silent: silent,
                             injectStaleFeedback: injectStaleFeedback, feedbackBatchCount: feedbackBatchCount)
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, tag: UInt8, silent: Bool,
                         injectStaleFeedback: Bool, feedbackBatchCount: Int) {
        connection.receiveMessage { [weak self] message, _, _, error in
            guard let self, !self.closed, error == nil else { return }
            if !silent, let command = message?.first {
                let sequence = command == 0xa9 ? message![2] : 0
                if command == 0xa9 {
                    self.receivedSequences.append(sequence)
                    self.waitingFeedback.append((connection, sequence))
                    // A delayed response to the previous packet must not satisfy
                    // the current packet's exchange.
                    if injectStaleFeedback {
                        connection.send(content: Data([0x8a, sequence &- 1, 0xff, 0]), completion: .contentProcessed { _ in })
                    }
                    if self.waitingFeedback.count == feedbackBatchCount {
                        for (peer, sequence) in self.waitingFeedback.reversed() {
                            peer.send(content: Data([0x8a, sequence, tag, 0]), completion: .contentProcessed { _ in })
                        }
                        self.waitingFeedback.removeAll()
                    }
                } else {
                    connection.send(content: Data([command, 0, tag]), completion: .contentProcessed { _ in })
                }
            }
            self.receive(connection, tag: tag, silent: silent,
                         injectStaleFeedback: injectStaleFeedback, feedbackBatchCount: feedbackBatchCount)
        }
    }

    func close() {
        let action = {
            guard !self.closed else { return }
            self.closed = true
            for listener in self.listeners { listener.cancel() }
            for connection in self.connections { connection.cancel() }
            self.connections.removeAll()
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { action() }
        else { queue.sync(execute: action) }
    }

    deinit { close() }
}

#endif
