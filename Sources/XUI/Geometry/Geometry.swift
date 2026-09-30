import Foundation

/// A width/height pair in layout points. Never negative.
public struct Size: Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public static let zero = Size(width: 0, height: 0)
}

/// A point in the canvas coordinate space (origin top-left, y down).
public struct Point: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)
}

/// An axis-aligned rectangle in canvas space.
public struct Rect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: Point, size: Size) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var origin: Point { Point(x: x, y: y) }
    public var size: Size { Size(width: width, height: height) }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func contains(_ point: Point) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    /// Shrink (positive) or grow (negative) on every edge.
    public func inset(by insets: EdgeInsets) -> Rect {
        Rect(
            x: x + insets.leading,
            y: y + insets.top,
            width: max(0, width - insets.leading - insets.trailing),
            height: max(0, height - insets.top - insets.bottom)
        )
    }

    public func offsetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: x + dx, y: y + dy, width: width, height: height)
    }
}

/// Per-edge spacing. `EdgeInsets()` is zero on every edge.
public struct EdgeInsets: Hashable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    /// The same length on all four edges.
    public init(_ length: Double) {
        self.init(top: length, leading: length, bottom: length, trailing: length)
    }

    public static let zero = EdgeInsets()
}

/// A named set of edges, for `.padding(_:_:)`.
public struct Edge: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let top = Edge(rawValue: 1 << 0)
    public static let leading = Edge(rawValue: 1 << 1)
    public static let bottom = Edge(rawValue: 1 << 2)
    public static let trailing = Edge(rawValue: 1 << 3)

    public static let horizontal: Edge = [.leading, .trailing]
    public static let vertical: Edge = [.top, .bottom]
    public static let all: Edge = [.top, .leading, .bottom, .trailing]

    func insets(_ length: Double) -> EdgeInsets {
        EdgeInsets(
            top: contains(.top) ? length : 0,
            leading: contains(.leading) ? length : 0,
            bottom: contains(.bottom) ? length : 0,
            trailing: contains(.trailing) ? length : 0
        )
    }
}
