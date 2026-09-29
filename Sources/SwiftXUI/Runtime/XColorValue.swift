import Foundation

/// A straight (non-premultiplied) RGBA colour, components in 0...1.
///
/// SwiftXUI stays deliberately ignorant of colour spaces and of the host's
/// colour type — the `XCanvas` adapter converts this to whatever the backend
/// wants (`RenderColor`, `CGColor`, …).
public struct XColorValue: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    public init(hex: UInt32, opacity: Double = 1) {
        self.init(
            Double((hex >> 16) & 0xff) / 255,
            Double((hex >> 8) & 0xff) / 255,
            Double(hex & 0xff) / 255,
            opacity
        )
    }

    public func opacity(_ value: Double) -> XColorValue {
        XColorValue(red, green, blue, opacity * value)
    }

    public static let clear = XColorValue(0, 0, 0, 0)
    public static let black = XColorValue(0, 0, 0)
    public static let white = XColorValue(1, 1, 1)
    public static let red = XColorValue(1, 0, 0)
    public static let green = XColorValue(0, 1, 0)
    public static let blue = XColorValue(0, 0, 1)
    public static let gray = XColorValue(0.5, 0.5, 0.5)
}
