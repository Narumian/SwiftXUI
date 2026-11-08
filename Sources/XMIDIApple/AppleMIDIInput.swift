import CoreMIDI
import Foundation
import XMIDI

public struct AppleMIDIError: Error, Sendable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
}

/// CoreMIDI MIDI 1.0 input. Query sources again after a device change.
public struct AppleMIDIInputBackend: MIDIInputBackend {
    public init() {}

    public func sources() throws -> [MIDIInputSource] {
        (0..<MIDIGetNumberOfSources()).compactMap { index in
            let endpoint = MIDIGetSource(index)
            return Self.describe(endpoint)
        }
    }

    public func connect(to source: MIDIInputSource) throws -> any MIDIInputConnection {
        guard let endpoint = (0..<MIDIGetNumberOfSources()).map({ MIDIGetSource($0) }).first(where: { Self.describe($0)?.id == source.id }) else {
            throw AppleMIDIError(status: kMIDIObjectNotFound)
        }
        return try AppleMIDIConnection(endpoint: endpoint, sourceID: source.id)
    }

    private static func describe(_ endpoint: MIDIEndpointRef) -> MIDIInputSource? {
        guard endpoint != 0 else { return nil }
        var id: Int32 = 0
        guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) == noErr else { return nil }
        var value: Unmanaged<CFString>?
        let result = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value)
        let name = result == noErr ? (value?.takeRetainedValue() as String? ?? "MIDI Input") : "MIDI Input"
        return MIDIInputSource(id: String(id), name: name)
    }
}

private final class AppleMIDIConnection: MIDIInputConnection, @unchecked Sendable {
    let events: AsyncStream<MIDIInputEvent>
    private let continuation: AsyncStream<MIDIInputEvent>.Continuation
    private let lock = NSLock()
    private var parser = MIDI1InputParser()
    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    private var endpoint: MIDIEndpointRef = 0
    private let sourceID: String
    private var closed = false

    init(endpoint: MIDIEndpointRef, sourceID: String) throws {
        self.sourceID = sourceID
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4096))
        var newClient: MIDIClientRef = 0
        var status = MIDIClientCreateWithBlock("XMIDI" as CFString, &newClient, nil)
        guard status == noErr else { throw AppleMIDIError(status: status) }
        client = newClient
        var newPort: MIDIPortRef = 0
        status = MIDIInputPortCreateWithBlock(client, "XMIDI Input" as CFString, &newPort) { [weak self] list, _ in
            self?.receive(list)
        }
        guard status == noErr else { MIDIClientDispose(client); client = 0; throw AppleMIDIError(status: status) }
        port = newPort
        status = MIDIPortConnectSource(port, endpoint, nil)
        guard status == noErr else { MIDIPortDispose(port); MIDIClientDispose(client); port = 0; client = 0; throw AppleMIDIError(status: status) }
        self.endpoint = endpoint
    }

    private func receive(_ list: UnsafePointer<MIDIPacketList>) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        withUnsafePointer(to: list.pointee.packet) { first in
            var packet = first
            for _ in 0..<list.pointee.numPackets {
                let messages = withUnsafePointer(to: packet.pointee.data) { data in
                    parser.receive(UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.length)))
                }
                for message in messages {
                    continuation.yield(MIDIInputEvent(sourceID: sourceID, message: message, timestamp: packet.pointee.timeStamp))
                }
                packet = UnsafePointer(MIDIPacketNext(packet))
            }
        }
    }

    func disconnect() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let oldPort = port, oldClient = client, oldEndpoint = endpoint
        port = 0; client = 0; endpoint = 0
        lock.unlock()
        if oldPort != 0 { MIDIPortDisconnectSource(oldPort, oldEndpoint); MIDIPortDispose(oldPort) }
        if oldClient != 0 { MIDIClientDispose(oldClient) }
        continuation.finish()
    }
    deinit { disconnect() }
}
