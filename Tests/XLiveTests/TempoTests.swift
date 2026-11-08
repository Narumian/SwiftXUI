import XCTest
import XLive
import XLiveApple

private struct FakeTransform: LiveSpectrumTransform {
    let frameCount = 4
    mutating func magnitudes(samples: [Float]) throws -> [Float] { samples }
}
private struct RecordingInferencer: TempoInferencer {
    var count = 0
    mutating func reset() { count = 0 }
    mutating func process(spectrum: [Float], time: Double) -> TempoEstimate {
        count += 1
        return .detected(bpm: Double(count) * 100 + Double(spectrum[0]) + time)
    }
}
final class TempoTests: XCTestCase {
    func testPipelineCombinesBuffersAndResetsOnDroppedSamples() throws {
        var analyzer = try LiveTempoAnalyzer(transform: FakeTransform(), inferencer: RecordingInferencer())
        XCTAssertTrue(try analyzer.process(.init(sampleRate: 4, channels: [[1, 1]], sampleTime: 0)).isEmpty)
        XCTAssertEqual(try analyzer.process(.init(sampleRate: 4, channels: [[1, 1]], sampleTime: 2)), [.detected(bpm: 102)])
        XCTAssertEqual(try analyzer.process(.init(sampleRate: 4, channels: [[1, 1, 1, 1]], sampleTime: 12)), [.detected(bpm: 102)])
    }
    func testDetectorAcceptsVariableLengthsAndSilence() {
        for size in [1, 127, 128, 129, 255, 512, 1000] {
            var detector = BeatDetektorTempoInferencer()
            for frame in 1...100 {
                XCTAssertEqual(detector.process(spectrum: Array(repeating: 0, count: size), time: Double(frame) / 30), .estimating)
            }
        }
    }
    func testAppleFFTIdentifiesSineFrequency() throws {
        let n = 1024, bin = 32
        let samples = (0..<n).map { Float(sin(2 * Double.pi * Double(bin * $0) / Double(n))) }
        var fft = try AppleSpectrumTransform(frameCount: n)
        let spectrum = try fft.magnitudes(samples: samples)
        let peak = spectrum.indices.max(by: { spectrum[$0] < spectrum[$1] })
        XCTAssertEqual(peak, bin)
    }
    func testPortableFFTMimicsAppleFFT() throws {
        let n = 1024
        let samples = (0..<n).map { Float(0.5 * sin(2 * Double.pi * 32 * Double($0) / Double(n)) + 0.2 * cos(2 * Double.pi * 81 * Double($0) / Double(n))) }
        var portable = try PortableSpectrumTransform(frameCount: n)
        var apple = try AppleSpectrumTransform(frameCount: n)
        let actual = try portable.magnitudes(samples: samples)
        let reference = try apple.magnitudes(samples: samples)
        XCTAssertEqual(actual.count, reference.count)
        for index in actual.indices { XCTAssertEqual(actual[index], reference[index], accuracy: 0.001, "bin \(index)") }
    }
    func testBeatDetektorProducesEstimateForPeriodicSpectrum() {
        var detector = BeatDetektorTempoInferencer()
        var detected: Double?
        for frame in 1...1800 {
            let amplitude: Float = frame % 30 < 4 ? 1 : 0
            if case .detected(let bpm) = detector.process(spectrum: Array(repeating: amplitude, count: 512), time: Double(frame) / 60) {
                detected = bpm
            }
        }
        XCTAssertNotNil(detected)
        if let detected { XCTAssertEqual(detected, 120, accuracy: 5) }
    }
}
