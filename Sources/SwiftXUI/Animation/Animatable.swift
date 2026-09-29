import Foundation

/// A value that can be blended between two states, so an animation can move it.
/// SwiftUI's `Animatable` asks for vector arithmetic; a plain interpolation is
/// all an immediate-mode tree needs.
public protocol Animatable: Equatable {
    /// The value `t` of the way from `a` to `b`. `t` may fall outside 0...1
    /// (a spring overshoots), so do not clamp it.
    static func interpolate(from a: Self, to b: Self, at t: Double) -> Self
}

extension Double: Animatable {
    public static func interpolate(from a: Double, to b: Double, at t: Double) -> Double {
        a + (b - a) * t
    }
}

extension Point: Animatable {
    public static func interpolate(from a: Point, to b: Point, at t: Double) -> Point {
        Point(x: Double.interpolate(from: a.x, to: b.x, at: t),
              y: Double.interpolate(from: a.y, to: b.y, at: t))
    }
}

extension Size: Animatable {
    public static func interpolate(from a: Size, to b: Size, at t: Double) -> Size {
        Size(width: Double.interpolate(from: a.width, to: b.width, at: t),
             height: Double.interpolate(from: a.height, to: b.height, at: t))
    }
}

extension Rect: Animatable {
    public static func interpolate(from a: Rect, to b: Rect, at t: Double) -> Rect {
        Rect(x: Double.interpolate(from: a.x, to: b.x, at: t),
             y: Double.interpolate(from: a.y, to: b.y, at: t),
             width: max(0, Double.interpolate(from: a.width, to: b.width, at: t)),
             height: max(0, Double.interpolate(from: a.height, to: b.height, at: t)))
    }
}

extension XColorValue: Animatable {
    public static func interpolate(from a: XColorValue, to b: XColorValue, at t: Double) -> XColorValue {
        func channel(_ x: Double, _ y: Double) -> Double { min(1, max(0, Double.interpolate(from: x, to: y, at: t))) }
        return XColorValue(channel(a.red, b.red), channel(a.green, b.green),
                           channel(a.blue, b.blue), channel(a.opacity, b.opacity))
    }
}
