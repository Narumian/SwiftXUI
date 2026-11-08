import Foundation

/// A snapshot of Float32 PCM audio. Each array contains one channel's samples.
public struct LiveAudioBuffer: Sendable {
    public let sampleRate: Double
    public let channels: [[Float]]
    /// Sample position in the capture device's timeline, when available.
    public let sampleTime: Int64?
    /// Host clock ticks in the capture backend's clock domain, when available.
    public let hostTime: UInt64?

    public init(sampleRate: Double, channels: [[Float]], sampleTime: Int64? = nil, hostTime: UInt64? = nil) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.sampleTime = sampleTime
        self.hostTime = hostTime
    }
}

/// One consumer reads buffers from each capture session. Stop releases capture resources.
public protocol LiveAudioInputSession: AnyObject, Sendable {
    var buffers: AsyncStream<LiveAudioBuffer> { get }
    func stop()
}

/// Permission and platform audio-session configuration belong to the host application.
public protocol LiveAudioInput: Sendable {
    func start() throws -> any LiveAudioInputSession
}
