import Foundation

/// A flexible rectangular fill. Like SwiftUI's `Rectangle`, it takes whatever
/// size the parent offers and collapses to a small ideal when unconstrained.
public struct Rectangle: XView, _PrimitiveXView, Sendable {
    public typealias Body = Never
    public var fill: XColorValue

    public init(fill: XColorValue = .black) {
        self.fill = fill
    }

    public func fill(_ color: XColorValue) -> Self {
        var copy = self
        copy.fill = color
        return copy
    }

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let node = LayoutNode(layout: FillLayout())
        let fill = fill
        node.draw = { rect, context in
            context.canvas.fillRect(rect, color: fill)
        }
        return [node]
    }
}

/// A flexible rounded-rectangle fill.
public struct RoundedRectangle: XView, _PrimitiveXView, Sendable {
    public typealias Body = Never
    public var cornerRadius: Double
    public var fill: XColorValue

    public init(cornerRadius: Double, fill: XColorValue = .black) {
        self.cornerRadius = cornerRadius
        self.fill = fill
    }

    public func fill(_ color: XColorValue) -> Self {
        var copy = self
        copy.fill = color
        return copy
    }

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let node = LayoutNode(layout: FillLayout())
        let cornerRadius = cornerRadius
        let fill = fill
        node.draw = { rect, context in
            context.canvas.fillRoundedRect(rect, cornerRadius: cornerRadius, color: fill)
        }
        return [node]
    }
}

/// A flexible elliptical fill inscribed in the resolved frame.
public struct Ellipse: XView, _PrimitiveXView, Sendable {
    public typealias Body = Never
    public var fill: XColorValue

    public init(fill: XColorValue = .black) {
        self.fill = fill
    }

    public func fill(_ color: XColorValue) -> Self {
        var copy = self
        copy.fill = color
        return copy
    }

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let node = LayoutNode(layout: FillLayout())
        let fill = fill
        node.draw = { rect, context in
            context.canvas.fillEllipse(in: rect, color: fill)
        }
        return [node]
    }
}

/// A circle that preserves a square frame by fitting inside the offered size.
public struct Circle: XView, _PrimitiveXView, Sendable {
    public typealias Body = Never
    public var fill: XColorValue

    public init(fill: XColorValue = .black) {
        self.fill = fill
    }

    public func fill(_ color: XColorValue) -> Self {
        var copy = self
        copy.fill = color
        return copy
    }

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let node = LayoutNode(layout: AspectRatioLayout(ratio: 1, contentMode: .fit, alignment: .center), children: [
            Ellipse(fill: fill)._lower(id: id.child(type: Ellipse.self), store: store)[0]
        ])
        return [node]
    }
}
