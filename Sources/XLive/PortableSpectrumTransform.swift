import Foundation

public enum PortableSpectrumError: Error, Equatable, Sendable {
    case invalidFrameCount, invalidSamples
}

/// Radix-2 FFT with precomputed bit reversal, twiddle factors, and a Hann window.
/// Results are scaled by 1 / frameCount and omit the Nyquist bin.
public struct PortableSpectrumTransform: LiveSpectrumTransform {
    public let frameCount: Int
    private let bitReversed: [Int]
    private let twiddles: [SIMD2<Float>]
    private let window: [Float]
    private var values: [SIMD2<Float>]

    public init(frameCount: Int = 1024) throws {
        guard frameCount >= 2, frameCount.nonzeroBitCount == 1 else { throw PortableSpectrumError.invalidFrameCount }
        self.frameCount = frameCount
        values = [SIMD2<Float>](repeating: .zero, count: frameCount)
        let bits = frameCount.trailingZeroBitCount
        bitReversed = (0..<frameCount).map { index in
            var value = index, reversed = 0
            for _ in 0..<bits { reversed = (reversed << 1) | (value & 1); value >>= 1 }
            return reversed
        }
        twiddles = (0..<(frameCount / 2)).map { index in
            let angle = -2 * Double.pi * Double(index) / Double(frameCount)
            return SIMD2(Float(cos(angle)), Float(sin(angle)))
        }
        window = (0..<frameCount).map { index in
            Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(frameCount)))
        }
    }

    public mutating func magnitudes(samples: [Float]) throws -> [Float] {
        guard samples.count == frameCount else { throw PortableSpectrumError.invalidSamples }
        for i in 0..<frameCount { values[bitReversed[i]] = SIMD2(samples[i] * window[i], 0) }
        var width = 2
        while width <= frameCount {
            let half = width / 2, step = frameCount / width
            for base in stride(from: 0, to: frameCount, by: width) {
                for i in 0..<half {
                    let w = twiddles[i * step], b = values[base + i + half]
                    let product = SIMD2(b.x * w.x - b.y * w.y, b.x * w.y + b.y * w.x)
                    let a = values[base + i]
                    values[base + i] = a + product
                    values[base + i + half] = a - product
                }
            }
            if width == frameCount { break }
            width *= 2
        }
        // vDSP's real FFT uses a factor of two relative to the conventional DFT.
        let scale = 2 / Float(frameCount)
        return values.prefix(frameCount / 2).map { sqrt($0.x * $0.x + $0.y * $0.y) * scale }
    }
}
