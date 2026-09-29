import Foundation

/// How a value gets from where it is to where it is going. Modelled on SwiftUI's
/// `Animation`: pick a curve, a duration, optionally a delay or a speed.
///
///     .easeOut(duration: 0.4)
///     .spring(response: 0.5, dampingFraction: 0.8)
///     .linear(duration: 1).delay(0.2)
///
/// An `Animation` is only a description. Time comes from the host's presentation
/// clock (`EnvironmentValues.fxTime`); see `View.animation(_:value:)`.
public struct Animation: Hashable, Sendable {
    public enum Curve: Hashable, Sendable {
        case linear
        case easeIn
        case easeOut
        case easeInOut
        /// A cubic Bézier through (0,0) and (1,1) with control points (c0x, c0y)
        /// and (c1x, c1y), as in CSS `cubic-bezier`.
        case timingCurve(Double, Double, Double, Double)
        /// A damped spring. `response` is the undamped period in seconds;
        /// `dampingFraction` 1 is critically damped, below 1 overshoots.
        case spring(response: Double, dampingFraction: Double)
    }

    public var curve: Curve
    /// Seconds from start to rest for a timed curve. A spring ignores this and
    /// rests when it has settled (see `restTime`).
    public var duration: Double
    /// Seconds to wait before the motion begins.
    public var delay: Double
    /// 2 plays twice as fast, 0.5 half as fast.
    public var speed: Double

    public init(curve: Curve, duration: Double = 0.35, delay: Double = 0, speed: Double = 1) {
        self.curve = curve
        self.duration = max(0.0001, duration)
        self.delay = max(0, delay)
        self.speed = max(0.0001, speed)
    }

    // MARK: Presets (SwiftUI names)

    public static let `default` = Animation.easeInOut
    public static var linear: Animation { linear() }
    public static var easeIn: Animation { easeIn() }
    public static var easeOut: Animation { easeOut() }
    public static var easeInOut: Animation { easeInOut() }

    public static func linear(duration: Double = 0.35) -> Animation { Animation(curve: .linear, duration: duration) }
    public static func easeIn(duration: Double = 0.35) -> Animation { Animation(curve: .easeIn, duration: duration) }
    public static func easeOut(duration: Double = 0.35) -> Animation { Animation(curve: .easeOut, duration: duration) }
    public static func easeInOut(duration: Double = 0.35) -> Animation { Animation(curve: .easeInOut, duration: duration) }

    public static func timingCurve(
        _ c0x: Double, _ c0y: Double, _ c1x: Double, _ c1y: Double, duration: Double = 0.35
    ) -> Animation {
        Animation(curve: .timingCurve(c0x, c0y, c1x, c1y), duration: duration)
    }

    public static func spring(response: Double = 0.5, dampingFraction: Double = 0.825) -> Animation {
        Animation(curve: .spring(response: response, dampingFraction: dampingFraction))
    }

    // MARK: Modifiers

    public func delay(_ seconds: Double) -> Animation {
        var copy = self
        copy.delay = max(0, seconds)
        return copy
    }

    public func speed(_ factor: Double) -> Animation {
        var copy = self
        copy.speed = max(0.0001, factor)
        return copy
    }

    // MARK: Evaluation

    /// Seconds from the start until the value is at rest, delay included.
    public var totalDuration: Double {
        delay + restTime / speed
    }

    /// Seconds of motion (at speed 1) before the value is at rest.
    var restTime: Double {
        switch curve {
        case .spring(let response, let damping):
            let omega = 2 * Double.pi / max(0.0001, response)
            let zeta = max(0.0001, damping)
            // The envelope e^(-ζωt) falls under 0.1% of the travel.
            return min(10, -log(0.001) / (zeta * omega))
        default:
            return duration
        }
    }

    /// How far along the motion is, `elapsed` seconds after the animation was
    /// started: 0 before it begins, 1 once it has come to rest. A spring can
    /// pass 1 on the way (overshoot).
    public func progress(elapsed: Double) -> Double {
        let t = (elapsed - delay) * speed
        guard t > 0 else { return 0 }
        guard t < restTime else { return 1 }
        switch curve {
        case .linear:
            return t / duration
        case .easeIn:
            let x = t / duration
            return x * x * x
        case .easeOut:
            let x = 1 - t / duration
            return 1 - x * x * x
        case .easeInOut:
            let x = t / duration
            return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        case .timingCurve(let c0x, let c0y, let c1x, let c1y):
            return Self.bezier(t / duration, c0x, c0y, c1x, c1y)
        case .spring(let response, let damping):
            return Self.spring(t, response: response, damping: damping)
        }
    }

    /// The Bézier's y at the given x (time), found by bisection on the x curve.
    private static func bezier(_ x: Double, _ c0x: Double, _ c0y: Double, _ c1x: Double, _ c1y: Double) -> Double {
        func axis(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
            let v = 1 - u
            return 3 * v * v * u * p1 + 3 * v * u * u * p2 + u * u * u
        }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if axis(mid, c0x, c1x) < x { low = mid } else { high = mid }
        }
        return axis((low + high) / 2, c0y, c1y)
    }

    /// The unit step response of a damped harmonic oscillator.
    private static func spring(_ t: Double, response: Double, damping: Double) -> Double {
        let omega = 2 * Double.pi / max(0.0001, response)
        let zeta = max(0.0001, damping)
        if zeta >= 1 {
            return 1 - exp(-omega * t) * (1 + omega * t)
        }
        let damped = omega * sqrt(1 - zeta * zeta)
        let decay = exp(-zeta * omega * t)
        return 1 - decay * (cos(damped * t) + (zeta * omega / damped) * sin(damped * t))
    }
}
