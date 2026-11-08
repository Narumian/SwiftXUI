import Foundation

public enum TempoEstimate: Equatable, Sendable {
    case estimating
    case detected(bpm: Double)
}

/// Receives nonnegative spectral magnitudes and a monotonically increasing time in seconds.
public protocol TempoInferencer: Sendable {
    mutating func process(spectrum: [Float], time: Double) -> TempoEstimate
    mutating func reset()
}

/// Adapts arbitrary spectrum lengths to the 128 bands required by BeatDetektor2.
public struct BeatDetektorTempoInferencer: TempoInferencer {
    private var detector = BeatDetektor2()
    private var previousTime: Double?
    public init() {}

    public mutating func reset() { detector = BeatDetektor2(); previousTime = nil }

    public mutating func process(spectrum: [Float], time: Double) -> TempoEstimate {
        guard !spectrum.isEmpty, time.isFinite, time >= 0,
              time < Double(Float.greatestFiniteMagnitude), spectrum.allSatisfy(\.isFinite) else { return .estimating }
        if let previousTime, time <= previousTime { reset() }
        self.previousTime = time
        // Distribute bins by overlap. This preserves the original average for multiples of 128
        // and avoids empty bands for short FFTs.
        let bands: [Float] = (0..<128).map { band in
            let start = Double(band) * Double(spectrum.count) / 128
            let end = Double(band + 1) * Double(spectrum.count) / 128
            let first = Int(start), last = min(spectrum.count - 1, Int(end.nextDown))
            var sum = 0.0
            for i in first...last {
                let weight = min(end, Double(i + 1)) - max(start, Double(i))
                sum += Double(abs(spectrum[i])) * weight
            }
            return Float(sum / (end - start))
        }
        detector.process(timerSeconds: Float(time), fftData: bands)
        let period = Double(detector.getBPM())
        guard period.isFinite, period > 0 else { return .estimating }
        let bpm = 60 / period
        return bpm.isFinite ? .detected(bpm: bpm) : .estimating
    }
}

/// A spectral transform operates on exactly `frameCount` mono PCM samples.
public protocol LiveSpectrumTransform: Sendable {
    var frameCount: Int { get }
    mutating func magnitudes(samples: [Float]) throws -> [Float]
}

public enum LiveTempoError: Error, Equatable, Sendable {
    case invalidAudioBuffer, invalidFrameCount
}

/// Stateful PCM-to-tempo pipeline. Feed buffers in capture order, away from the audio callback.
public struct LiveTempoAnalyzer: Sendable {
    private var transform: any LiveSpectrumTransform
    private var inferencer: any TempoInferencer
    private var pending: [Float] = []
    private var sampleRate: Double?
    private var expectedSampleTime: Int64?
    private var elapsedSamples: Int64 = 0

    public init(transform: any LiveSpectrumTransform, inferencer: any TempoInferencer) throws {
        guard transform.frameCount > 0 else { throw LiveTempoError.invalidFrameCount }
        self.transform = transform; self.inferencer = inferencer
    }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true); sampleRate = nil
        expectedSampleTime = nil; elapsedSamples = 0; inferencer.reset()
    }

    /// Returns one estimate per completed FFT window.
    public mutating func process(_ buffer: LiveAudioBuffer) throws -> [TempoEstimate] {
        guard buffer.sampleRate.isFinite, buffer.sampleRate > 0, let first = buffer.channels.first,
              !first.isEmpty, buffer.channels.allSatisfy({ $0.count == first.count && $0.allSatisfy(\.isFinite) }) else {
            throw LiveTempoError.invalidAudioBuffer
        }
        if let sampleRate, sampleRate != buffer.sampleRate { reset() }
        if let expectedSampleTime, let sampleTime = buffer.sampleTime, expectedSampleTime != sampleTime { reset() }
        sampleRate = buffer.sampleRate
        expectedSampleTime = buffer.sampleTime.flatMap { $0.addingReportingOverflow(Int64(first.count)).overflow ? nil : $0 + Int64(first.count) }
        let scale = 1 / Float(buffer.channels.count)
        for i in first.indices {
            var mixed: Float = 0
            for channel in buffer.channels { mixed += channel[i] * scale }
            pending.append(mixed)
        }
        var result: [TempoEstimate] = []
        let size = transform.frameCount
        var offset = 0
        while pending.count - offset >= size {
            let spectrum = try transform.magnitudes(samples: Array(pending[offset..<(offset + size)]))
            elapsedSamples += Int64(size)
            result.append(inferencer.process(spectrum: spectrum, time: Double(elapsedSamples) / buffer.sampleRate))
            offset += size
        }
        if offset > 0 { pending.removeFirst(offset) }
        return result
    }
}
