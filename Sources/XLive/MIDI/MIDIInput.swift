import Foundation
import XCombine

public struct MIDIInputSource: Identifiable, Hashable, Sendable {
    /// Stable identifier supplied by the backend, when the platform provides one.
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum MIDIMessage: Equatable, Sendable {
    /// Channels are zero-based, in the range 0...15.
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
}

public struct MIDIInputEvent: Equatable, Sendable {
    public let sourceID: String
    public let message: MIDIMessage
    /// Backend-specific timestamp; CoreMIDI uses host time ticks. Zero means unspecified.
    public let timestamp: UInt64
    public init(sourceID: String, message: MIDIMessage, timestamp: UInt64) {
        self.sourceID = sourceID; self.message = message; self.timestamp = timestamp
    }
}

/// A connected source. Events arrive on the backend's own thread and are queued in `events`;
/// the owner of the graph calls `events.drain()` (once per frame, or when `events.onWake`
/// fires) and they are delivered on that thread to any number of subscribers. After
/// `disconnect()` no further events are queued.
public protocol MIDIInputConnection: AnyObject, Sendable {
    var events: XInbox<MIDIInputEvent> { get }
    func disconnect()
}

public protocol MIDIInputBackend: Sendable {
    func sources() throws -> [MIDIInputSource]
    func connect(to source: MIDIInputSource) throws -> any MIDIInputConnection
}

/// Incremental MIDI 1.0 byte stream parser. Retain one instance per source.
public struct MIDI1InputParser: Sendable {
    private var runningStatus: UInt8?
    private var status: UInt8?
    private var bytes: [UInt8] = []
    private var inSysEx = false
    public init() {}

    public mutating func receive<S: Sequence>(_ input: S) -> [MIDIMessage] where S.Element == UInt8 {
        var result: [MIDIMessage] = []
        for byte in input {
            if byte >= 0xF8 { continue } // Real-time bytes can occur inside any message.
            if byte & 0x80 != 0 {
                bytes.removeAll(keepingCapacity: true)
                if byte >= 0xF0 {
                    runningStatus = nil; status = nil
                    inSysEx = byte == 0xF0
                    continue
                }
                inSysEx = false
                runningStatus = byte; status = byte
                continue
            }
            guard !inSysEx, let current = status ?? runningStatus else { continue }
            status = current
            bytes.append(byte)
            let type = current & 0xF0
            let required = (type == 0xC0 || type == 0xD0) ? 1 : 2
            guard bytes.count == required else { continue }
            let channel = current & 0x0F
            switch type {
            case 0x80: result.append(.noteOff(channel: channel, note: bytes[0], velocity: bytes[1]))
            case 0x90:
                if bytes[1] == 0 { result.append(.noteOff(channel: channel, note: bytes[0], velocity: 0)) }
                else { result.append(.noteOn(channel: channel, note: bytes[0], velocity: bytes[1])) }
            case 0xB0: result.append(.controlChange(channel: channel, controller: bytes[0], value: bytes[1]))
            default: break
            }
            bytes.removeAll(keepingCapacity: true)
            status = runningStatus
        }
        return result
    }
}
