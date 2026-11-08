import Foundation

/// A one-pole follower with separate rise and fall times. With equal times it is a plain
/// smoother. Time-based, so the result does not depend on how often it is called.
public struct LiveEnvelope: Equatable, Sendable, Codable {
    /// Seconds to close about 63% of the gap while rising. Zero follows instantly.
    public let attack: Double
    /// Seconds to close about 63% of the gap while falling. Zero follows instantly.
    public let release: Double
    public private(set) var value: Double

    /// Times are clamped to 0 or more; infinity never moves in that direction.
    public init(attack: Double, release: Double, initial: Double = 0) {
        self.attack = attack.isNaN ? 0 : max(0, attack)
        self.release = release.isNaN ? 0 : max(0, release)
        self.value = initial.isFinite ? initial : 0
    }

    /// The envelope that matches a follower written as "move this fraction of the gap each
    /// frame" at `frameRate` (for example 0.3 up and 0.1 down at 60 fps).
    public init(perFrameRise rise: Double, fall: Double, frameRate: Double = 60, initial: Double = 0) {
        self.init(attack: Self.timeConstant(perFrame: rise, frameRate: frameRate),
                  release: Self.timeConstant(perFrame: fall, frameRate: frameRate),
                  initial: initial)
    }

    public static func timeConstant(perFrame fraction: Double, frameRate: Double) -> Double {
        guard fraction.isFinite, frameRate.isFinite, frameRate > 0 else { return 0 }
        if fraction >= 1 { return 0 }
        if fraction <= 0 { return .infinity }
        return -1 / (frameRate * log(1 - fraction))
    }

    /// Moves toward `target` over `deltaTime` seconds and returns the new value.
    /// A non-finite target or step leaves the value unchanged.
    @discardableResult
    public mutating func process(_ target: Double, deltaTime: Double) -> Double {
        guard target.isFinite, deltaTime.isFinite, deltaTime > 0 else { return value }
        let tau = target >= value ? attack : release
        let blend = tau == 0 ? 1 : 1 - exp(-deltaTime / tau)
        value += (target - value) * blend
        return value
    }

    /// Jumps to `newValue` without smoothing.
    public mutating func reset(to newValue: Double) {
        if newValue.isFinite { value = newValue }
    }
}
