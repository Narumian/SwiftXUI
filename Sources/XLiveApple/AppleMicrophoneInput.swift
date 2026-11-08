import AVFoundation
import Foundation
import XLive

public enum AppleMicrophoneError: Error, Sendable {
    case inputUnavailable
    case unsupportedFormat
}

/// Captures the current system input. The host requests microphone permission and, on
/// iOS, configures and activates AVAudioSession before starting capture.
public struct AppleMicrophoneInput: LiveAudioInput {
    public let bufferFrames: UInt32
    public let bufferedCount: Int

    public init(bufferFrames: UInt32 = 1024, bufferedCount: Int = 8) {
        self.bufferFrames = max(1, bufferFrames)
        self.bufferedCount = max(1, bufferedCount)
    }

    public func start() throws -> any LiveAudioInputSession {
        try AppleMicrophoneSession(bufferFrames: bufferFrames, bufferedCount: bufferedCount)
    }
}

private final class AppleMicrophoneSession: LiveAudioInputSession, @unchecked Sendable {
    let buffers: AsyncStream<LiveAudioBuffer>
    private let continuation: AsyncStream<LiveAudioBuffer>.Continuation
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var stopped = false

    init(bufferFrames: UInt32, bufferedCount: Int) throws {
        (buffers, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(bufferedCount))
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AppleMicrophoneError.inputUnavailable }
        guard format.commonFormat == .pcmFormatFloat32 else { throw AppleMicrophoneError.unsupportedFormat }
        let sink = continuation
        input.installTap(onBus: 0, bufferSize: bufferFrames, format: format) { buffer, time in
            guard let data = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            let stride = Int(buffer.stride)
            let channels = (0..<channelCount).map { channel in
                (0..<count).map { data[channel][$0 * stride] }
            }
            sink.yield(LiveAudioBuffer(sampleRate: buffer.format.sampleRate, channels: channels,
                                       sampleTime: time.isSampleTimeValid ? time.sampleTime : nil,
                                       hostTime: time.isHostTimeValid ? time.hostTime : nil))
        }
        do { try engine.start() }
        catch { input.removeTap(onBus: 0); continuation.finish(); throw error }
    }

    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        lock.unlock()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        continuation.finish()
    }

    deinit { stop() }
}
