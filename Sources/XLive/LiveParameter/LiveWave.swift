import Foundation

public enum LiveWaveShape: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case sin, cos, tri, saw, square, pwm
    /// Smooth value noise: random lattice values, eased between.
    case noise
    /// Sample and hold: one random value per cycle.
    case random
}

/// A periodic or random signal as a pure function of position in cycles. It has no clock:
/// the caller supplies the position (see `LivePhase`). Output is always in 0...1.
///
/// Randomness comes from `seed` through a hash, never from a global table, so the same
/// seed gives the same signal after a save and reload.
public struct LiveWave: Equatable, Hashable, Sendable, Codable {
    public var shape: LiveWaveShape
    /// Fraction of the cycle spent high, for `.pwm`. Kept inside 0...1.
    public private(set) var pulseWidth: Double
    public var seed: UInt64

    public init(shape: LiveWaveShape = .sin, pulseWidth: Double = 0.125, seed: UInt64 = 0) {
        self.shape = shape
        self.pulseWidth = pulseWidth.isFinite ? min(1, max(0, pulseWidth)) : 0.125
        self.seed = seed
    }

    private enum CodingKeys: String, CodingKey { case shape, pulseWidth, seed }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(shape: try container.decode(LiveWaveShape.self, forKey: .shape),
                  pulseWidth: try container.decodeIfPresent(Double.self, forKey: .pulseWidth) ?? 0.125,
                  seed: try container.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0)
    }

    public mutating func setPulseWidth(_ width: Double) {
        guard width.isFinite else { return }
        pulseWidth = min(1, max(0, width))
    }

    /// `cycles` may be any finite number, negative included. A non-finite position gives the midpoint.
    public func sample(cycles: Double) -> Double {
        guard cycles.isFinite else { return 0.5 }
        let whole = cycles.rounded(.down)
        let position = LivePhase.Position(cycleIndex: Self.latticeIndex(whole), fraction: cycles - whole)
        return sample(position: position)
    }

    /// Samples from a phase that retains both its cycle number and position within that cycle.
    public func sample(position: LivePhase.Position) -> Double {
        let whole = position.cycleIndex
        let fraction = position.fraction
        switch shape {
        case .sin: return sin(fraction * 2 * .pi) * 0.5 + 0.5
        case .cos: return cos(fraction * 2 * .pi) * 0.5 + 0.5
        case .tri: return fraction < 0.5 ? fraction * 2 : 2 - fraction * 2
        case .saw: return fraction
        case .square: return fraction < 0.5 ? 0 : 1
        case .pwm: return fraction < pulseWidth ? 1 : 0
        case .noise:
            let eased = fraction * fraction * (3 - 2 * fraction)
            let a = lattice(whole), b = lattice(whole &+ 1)
            return a * (1 - eased) + b * eased
        case .random: return lattice(whole)
        }
    }

    /// Keeps the legacy Double-based sampler safe for positions outside Int64's range.
    private static func latticeIndex(_ index: Double) -> Int64 {
        Int64(max(-9e15, min(9e15, index)))
    }

    /// A reproducible value in 0..<1 for each whole cycle (SplitMix64 over seed and index).
    private func lattice(_ index: Int64) -> Double {
        var z = seed &+ UInt64(bitPattern: index) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
