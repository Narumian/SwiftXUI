import Foundation

/// A solid fill. Infinitely flexible, like SwiftUI's `Color` — it takes whatever
/// size its parent offers.
public struct Color: XView, _PrimitiveXView, Sendable {
    public typealias Body = Never
    public var value: XColorValue

    public init(_ value: XColorValue) {
        self.value = value
    }

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.value = XColorValue(red, green, blue, opacity)
    }

    public init(hex: UInt32, opacity: Double = 1) {
        self.value = XColorValue(hex: hex, opacity: opacity)
    }

    public func opacity(_ amount: Double) -> Color {
        Color(value.opacity(amount))
    }

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let node = LayoutNode(layout: FillLayout())
        let fill = value
        node.draw = { rect, context in
            context.canvas.fillRect(rect, color: fill)
        }
        return [node]
    }

    public static let clear = Color(.clear)
    public static let black = Color(.black)
    public static let white = Color(.white)
    public static let red = Color(.red)
    public static let green = Color(.green)
    public static let blue = Color(.blue)
    public static let gray = Color(.gray)
}
