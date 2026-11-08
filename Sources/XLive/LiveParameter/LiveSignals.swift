import Foundation

/// Audio level readings, each normalised to 0...1. Computed by an analyzer outside the
/// parameter; the parameter only chooses a band.
public struct LiveAudioLevels: Equatable, Sendable, Codable {
    public var peak: Double
    public var low: Double
    public var mid: Double
    public var high: Double
    public init(peak: Double = 0, low: Double = 0, mid: Double = 0, high: Double = 0) {
        self.peak = peak; self.low = low; self.mid = mid; self.high = high
    }
}

public enum LiveAudioBand: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case peak, low, mid, high

    public func level(in levels: LiveAudioLevels) -> Double {
        let value: Double
        switch self {
        case .peak: value = levels.peak
        case .low: value = levels.low
        case .mid: value = levels.mid
        case .high: value = levels.high
        }
        return value.isFinite ? min(1, max(0, value)) : 0
    }
}

public struct LiveVector3: Equatable, Sendable, Codable {
    public var x: Double, y: Double, z: Double
    public init(x: Double = 0, y: Double = 0, z: Double = 0) { self.x = x; self.y = y; self.z = z }
}

/// A device motion reading. Acceleration and gravity are in g; attitude angles are in radians
/// (roll and yaw in -π...π, pitch in -π/2...π/2 on Apple devices).
public struct LiveMotionSample: Equatable, Sendable, Codable {
    public var acceleration: LiveVector3
    public var gravity: LiveVector3
    public var roll: Double, pitch: Double, yaw: Double
    public init(acceleration: LiveVector3 = .init(), gravity: LiveVector3 = .init(),
                roll: Double = 0, pitch: Double = 0, yaw: Double = 0) {
        self.acceleration = acceleration; self.gravity = gravity
        self.roll = roll; self.pitch = pitch; self.yaw = yaw
    }
}

/// One motion channel, read as a 0...1 signal. Signed channels map -1...1 (or -π...π for
/// angles) onto 0...1 with 0 at the middle; the `Abs` channels read the magnitude.
public enum LiveMotionAxis: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case accelX, accelY, accelZ, gravityX, gravityY, gravityZ
    case roll, pitch, yaw
    case accelXAbs, accelYAbs, accelZAbs, gravityXAbs, gravityYAbs, gravityZAbs

    public func normalized(from sample: LiveMotionSample) -> Double {
        func signed(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v / 2 + 0.5)) : 0.5 }
        func magnitude(_ v: Double) -> Double { v.isFinite ? min(1, abs(v)) : 0 }
        switch self {
        case .accelX: return signed(sample.acceleration.x)
        case .accelY: return signed(sample.acceleration.y)
        case .accelZ: return signed(sample.acceleration.z)
        case .gravityX: return signed(sample.gravity.x)
        case .gravityY: return signed(sample.gravity.y)
        case .gravityZ: return signed(sample.gravity.z)
        case .roll: return signed(sample.roll / .pi)
        case .pitch: return signed(sample.pitch / .pi)
        case .yaw: return signed(sample.yaw / .pi)
        case .accelXAbs: return magnitude(sample.acceleration.x)
        case .accelYAbs: return magnitude(sample.acceleration.y)
        case .accelZAbs: return magnitude(sample.acceleration.z)
        case .gravityXAbs: return magnitude(sample.gravity.x)
        case .gravityYAbs: return magnitude(sample.gravity.y)
        case .gravityZAbs: return magnitude(sample.gravity.z)
        }
    }
}
