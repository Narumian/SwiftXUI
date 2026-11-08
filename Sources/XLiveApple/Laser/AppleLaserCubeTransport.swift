import Foundation
import Network
import XLive

public enum AppleLaserCubeError: Error, Equatable, Sendable {
    case invalidIPv4Address, endpointInUse, tooManyRequests
    case network(String)
}

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public extension LaserCube {
    /// Uses remote UDP ports 45457/45458 and OS-assigned ephemeral local ports.
    /// Real WiFi Cube FW 0.12 replies to the source port on both channels. Receives
    /// only from this peer; no fixed local bind, port sharing, or discovery is used.
    /// Supply an explicit ID to keep identity independent of a configured IP.
    ///
    /// Every sample packet is sent twice back to back (`duplicatesSamplePackets`), a
    /// long-standing trick for this device over lossy Wi-Fi: the cube discards the
    /// second copy by its sequence number, so a single dropped UDP datagram no
    /// longer loses 140 samples.
    init(host: String, id: String? = nil, name: String = "LaserCube", underrunPolicy: LaserCubeUnderrunPolicy = .fail,
         duplicatesSamplePackets: Bool = true) {
        self.init(id: id ?? "lasercube-network:\(host)", name: name, underrunPolicy: underrunPolicy) {
            try AppleLaserCubeTransport(host: host, duplicatesSamplePackets: duplicatesSamplePackets)
        }
    }
}

/// Apple networking stays outside the portable XLive driver. Sandbox and local
/// network permissions must be configured by the host application.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public final class AppleLaserCubeTransport: LaserCubeTransport, @unchecked Sendable {
    private static let leases = PeerLeases()
    private let command: CubeUDPChannel
    private let data: CubeUDPChannel
    private let peer: String
    private let lock = NSLock()
    private var closed = false

    public convenience init(host: String, duplicatesSamplePackets: Bool = false) throws {
        try self.init(host: host, commandPort: 45457, dataPort: 45458, duplicatesSamplePackets: duplicatesSamplePackets)
    }

    // Remote port injection is internal for loopback integration tests. Production
    // uses the vendor's remote ports and independent ephemeral local ports.
    init(host: String, commandPort: UInt16, dataPort: UInt16, duplicatesSamplePackets: Bool = false) throws {
        guard let address = IPv4Address(host), let first = address.rawValue.first,
              first > 0, first < 224 else { throw AppleLaserCubeError.invalidIPv4Address }
        peer = address.rawValue.map(String.init).joined(separator: ".") + ":\(commandPort):\(dataPort)"
        guard Self.leases.acquire(peer) else { throw AppleLaserCubeError.endpointInUse }
        command = CubeUDPChannel(address: address, port: commandPort)
        data = CubeUDPChannel(address: address, port: dataPort, duplicatesSamples: duplicatesSamplePackets)
    }

    public func exchange(_ message: Data, on channel: LaserCubeChannel, timeout: Duration) async throws -> Data {
        switch channel {
        case .command: try await command.exchange(message, timeout: timeout)
        case .data: try await data.exchange(message, timeout: timeout)
        }
    }

    public func exchangeSamples(_ packets: [Data], timeout: Duration) async throws -> [Data] {
        try await data.exchangeBatch(packets, timeout: timeout)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        command.close(); data.close()
        Self.leases.release(peer)
    }

    deinit { close() }
}

private final class PeerLeases: @unchecked Sendable {
    private let lock = NSLock()
    private var peers = Set<String>()
    func acquire(_ peer: String) -> Bool { lock.withLock { peers.insert(peer).inserted } }
    func release(_ peer: String) { _ = lock.withLock { peers.remove(peer) } }
}

private final class CubeRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Mutable request state is confined to this channel's serial dispatch queue.
/// Receiving runs continuously. Command requests are serialized; sample requests
/// are sent in array order with at most 20 correlated packets in flight.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
private final class CubeUDPChannel: @unchecked Sendable {
    private struct Request {
        let id: UUID
        let batchID: UUID
        let index: Int
        let message: Data
        let responseCommand: UInt8
        let responseSequence: UInt8?
    }
    private final class Batch {
        let continuation: CheckedContinuation<[Data], any Error>
        let deadline: DispatchWorkItem
        var replies: [Data?]
        var remaining: Int
        init(count: Int, continuation: CheckedContinuation<[Data], any Error>, deadline: DispatchWorkItem) {
            self.replies = Array(repeating: nil, count: count)
            self.remaining = count; self.continuation = continuation; self.deadline = deadline
        }
    }
    private let connection: NWConnection
    /// Sample packets go out twice back to back; the device drops the repeat by sequence.
    private let duplicatesSamples: Bool
    private let queue = DispatchQueue(label: "XLive.LaserCube.UDP.\(UUID())")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var ready = false
    private var closed = false
    private var terminalError: (any Error)?
    private var receiving = false
    private var pending: [Request] = []
    private var active: [UUID: Request] = [:]
    private var batches: [UUID: Batch] = [:]

    init(address: IPv4Address, port: UInt16, duplicatesSamples: Bool = false) {
        self.duplicatesSamples = duplicatesSamples
        let parameters = NWParameters.udp
        // Let the OS choose a fresh source port. Reusing a fixed local endpoint
        // immediately after cancellation can fail while its old NECP flow retires.
        connection = NWConnection(host: .ipv4(address), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        queue.setSpecific(key: queueKey, value: true)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.ready = true
                if !self.receiving { self.receiving = true; self.receive() }
                self.beginNext()
            case .failed(let error): self.fail(AppleLaserCubeError.network(String(describing: error)))
            case .cancelled: self.fail(LaserOutputError.disconnected)
            default: break // Waiting for connectivity is bounded by request timeout.
            }
        }
        connection.start(queue: queue)
    }

    func exchange(_ message: Data, timeout: Duration) async throws -> Data {
        let replies = try await exchangeBatch([message], timeout: timeout)
        return replies[0]
    }

    func exchangeBatch(_ messages: [Data], timeout: Duration) async throws -> [Data] {
        try Task.checkCancellation()
        guard !messages.isEmpty, messages.count <= 20, timeout > .zero,
              messages.allSatisfy({ !$0.isEmpty && ($0.first != 0xa9 || $0.count >= 4) }),
              messages.count == 1 || messages.allSatisfy({ $0.first == 0xa9 })
        else { throw LaserCubeError.malformedResponse }
        let id = UUID()
        let cancellation = CubeRequestCancellation()
        let components = timeout.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if cancellation.isCancelled { continuation.resume(throwing: CancellationError()); return }
                    if self.closed { continuation.resume(throwing: LaserOutputError.disconnected); return }
                    if let error = self.terminalError { continuation.resume(throwing: error); return }
                    guard self.pending.count + self.active.count + messages.count <= 64 else {
                        continuation.resume(throwing: AppleLaserCubeError.tooManyRequests); return
                    }
                    let deadline = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        let outstanding = (Array(self.active.values) + self.pending).filter { $0.batchID == id }
                        let description = outstanding.map {
                            "cmd=\($0.message.first!) seq=\($0.responseSequence.map(String.init) ?? "none")"
                        }.joined(separator: ", ")
                        NSLog("LaserCube UDP timeout: %@", description)
                        self.removeBatch(id, error: LaserCubeError.timeout)
                    }
                    self.batches[id] = Batch(count: messages.count, continuation: continuation, deadline: deadline)
                    for (index, message) in messages.enumerated() {
                        let command = message.first!
                        self.pending.append(Request(id: UUID(), batchID: id, index: index, message: message,
                                                    responseCommand: command == 0xa9 ? 0x8a : command,
                                                    responseSequence: command == 0xa9 ? message[message.startIndex + 2] : nil))
                    }
                    self.queue.asyncAfter(deadline: .now() + seconds, execute: deadline)
                    self.beginNext()
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.queue.async { self.removeBatch(id, error: CancellationError()) }
        }
    }

    private func beginNext() {
        guard ready, !closed, terminalError == nil else { return }
        while let next = pending.first {
            let limit = next.responseSequence == nil ? 1 : 20
            guard active.count < limit else { return }
            let request = pending.removeFirst()
            active[request.id] = request
            let batchID = request.batchID
            connection.send(content: request.message, completion: .contentProcessed { [weak self] error in
                if let error { self?.removeBatch(batchID, error: AppleLaserCubeError.network(String(describing: error))) }
            })
            if duplicatesSamples, request.responseSequence != nil {
                // The repeat is best effort: its failure must not fail the batch.
                connection.send(content: request.message, completion: .contentProcessed { _ in })
            }
        }
    }

    private func receive() {
        connection.receiveMessage { [weak self] bytes, _, _, error in
            guard let self, !self.closed else { return }
            if let error { self.fail(AppleLaserCubeError.network(String(describing: error))); return }
            if let bytes, let request = self.active.values.first(where: {
                bytes.first == $0.responseCommand && ($0.responseSequence == nil ||
                (bytes.count >= 2 && bytes[bytes.startIndex + 1] == $0.responseSequence))
            }) {
                self.active.removeValue(forKey: request.id)
                if let batch = self.batches[request.batchID] {
                    batch.replies[request.index] = bytes
                    batch.remaining -= 1
                    if batch.remaining == 0 {
                        self.batches.removeValue(forKey: request.batchID)
                        batch.deadline.cancel()
                        batch.continuation.resume(returning: batch.replies.map { $0! })
                    }
                }
                self.beginNext()
            }
            self.receive()
        }
    }

    private func removeBatch(_ id: UUID, error: any Error) {
        guard let batch = batches.removeValue(forKey: id) else { return }
        pending.removeAll { $0.batchID == id }
        active = active.filter { $0.value.batchID != id }
        batch.deadline.cancel()
        batch.continuation.resume(throwing: error)
        beginNext()
    }

    private func fail(_ error: any Error) {
        terminalError = error
        let requests = Array(batches.values)
        active.removeAll(); pending.removeAll(); batches.removeAll()
        for batch in requests {
            batch.deadline.cancel()
            batch.continuation.resume(throwing: error)
        }
    }

    func close() {
        let action = {
            guard !self.closed else { return }
            self.closed = true
            self.fail(LaserOutputError.disconnected)
            self.connection.forceCancel()
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { action() }
        else { queue.sync(execute: action) }
    }

    deinit { connection.cancel() }
}
