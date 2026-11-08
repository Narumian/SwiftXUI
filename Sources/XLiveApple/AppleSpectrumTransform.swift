import Accelerate
import Foundation
import XLive

public enum AppleSpectrumError: Error, Sendable {
    case invalidFrameCount, setupFailed, invalidSamples
}

/// Hann-windowed real FFT. The result contains `frameCount / 2` magnitude bins.
public struct AppleSpectrumTransform: LiveSpectrumTransform {
    public let frameCount: Int
    private let state: FFTState

    public init(frameCount: Int = 1024) throws {
        guard frameCount >= 256, frameCount.nonzeroBitCount == 1 else { throw AppleSpectrumError.invalidFrameCount }
        self.frameCount = frameCount
        state = try FFTState(frameCount: frameCount)
    }

    public mutating func magnitudes(samples: [Float]) throws -> [Float] {
        guard samples.count == frameCount else { throw AppleSpectrumError.invalidSamples }
        var windowed = [Float](repeating: 0, count: frameCount)
        vDSP_vmul(samples, 1, state.window, 1, &windowed, 1, vDSP_Length(frameCount))
        var real = [Float](repeating: 0, count: frameCount / 2)
        var imag = [Float](repeating: 0, count: frameCount / 2)
        var output = [Float](repeating: 0, count: frameCount / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                windowed.withUnsafeBytes { bytes in
                    vDSP_ctoz(bytes.baseAddress!.assumingMemoryBound(to: DSPComplex.self), 2, &split, 1, vDSP_Length(frameCount / 2))
                }
                vDSP_fft_zrip(state.setup, &split, 1, state.log2Size, FFTDirection(FFT_FORWARD))
                // DC and Nyquist are packed into the first complex element.
                split.imagp[0] = 0
                vDSP_zvabs(&split, 1, &output, 1, vDSP_Length(frameCount / 2))
            }
        }
        var scale = 1 / Float(frameCount)
        vDSP_vsmul(output, 1, &scale, &output, 1, vDSP_Length(frameCount / 2))
        return output
    }
}

private final class FFTState: @unchecked Sendable {
    let setup: FFTSetup
    let log2Size: vDSP_Length
    let window: [Float]
    init(frameCount: Int) throws {
        log2Size = vDSP_Length(frameCount.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(FFT_RADIX2)) else { throw AppleSpectrumError.setupFailed }
        self.setup = setup
        var window = [Float](repeating: 0, count: frameCount)
        vDSP_hann_window(&window, vDSP_Length(frameCount), 0)
        self.window = window
    }
    deinit { vDSP_destroy_fftsetup(setup) }
}
