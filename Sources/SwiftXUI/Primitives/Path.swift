import Foundation

/// A small, renderer-neutral vector path.
///
/// The first version is deliberately linear: move, line, close. That covers
/// game UI silhouettes, arrows, dividers, and badges without pulling curves or
/// boolean geometry into the core layout engine too early.
public struct Path: XView, _PrimitiveXView, Hashable, Sendable {
    public enum Element: Hashable, Sendable {
        case move(to: Point)
        case line(to: Point)
        case closeSubpath
    }

    public struct Subpath: Hashable, Sendable {
        public var points: [Point]
        public var closed: Bool

        public init(points: [Point], closed: Bool = false) {
            self.points = points
            self.closed = closed
        }
    }

    enum Style: Hashable, Sendable {
        case fill(XColorValue)
        case stroke(XColorValue, lineWidth: Double)
    }

    public var elements: [Element]
    var style: Style

    public init() {
        self.elements = []
        self.style = .fill(.black)
    }

    public init(_ build: (inout Path) -> Void) {
        self.init()
        build(&self)
    }

    public init(points: [Point], closed: Bool = true) {
        self.init()
        guard let first = points.first else { return }
        move(to: first)
        for point in points.dropFirst() {
            addLine(to: point)
        }
        if closed {
            closeSubpath()
        }
    }

    public mutating func move(to point: Point) {
        elements.append(.move(to: point))
    }

    public mutating func addLine(to point: Point) {
        elements.append(.line(to: point))
    }

    public mutating func closeSubpath() {
        elements.append(.closeSubpath)
    }

    public func fill(_ color: XColorValue) -> Self {
        var copy = self
        copy.style = .fill(color)
        return copy
    }

    public func stroke(_ color: XColorValue, lineWidth: Double = 1) -> Self {
        var copy = self
        copy.style = .stroke(color, lineWidth: lineWidth)
        return copy
    }

    public var bounds: Rect? {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for point in authoredPoints {
            minX = Swift.min(minX, point.x)
            minY = Swift.min(minY, point.y)
            maxX = Swift.max(maxX, point.x)
            maxY = Swift.max(maxY, point.y)
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return nil }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public func subpaths(fittedIn rect: Rect) -> [Subpath] {
        let fit = PathFitter(source: bounds, destination: rect)
        var result: [Subpath] = []
        var current: [Point] = []

        func finish(closed: Bool) {
            guard !current.isEmpty else { return }
            result.append(Subpath(points: current, closed: closed))
            current.removeAll(keepingCapacity: true)
        }

        for element in elements {
            switch element {
            case .move(let point):
                finish(closed: false)
                current.append(fit(point))
            case .line(let point):
                if current.isEmpty {
                    current.append(fit(point))
                } else {
                    current.append(fit(point))
                }
            case .closeSubpath:
                finish(closed: true)
            }
        }
        finish(closed: false)
        return result
    }

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let node = LayoutNode(layout: PathLayout(path: self))
        let path = self
        node.draw = { rect, context in
            switch path.style {
            case .fill(let color):
                context.canvas.fillPath(path, in: rect, color: color)
            case .stroke(let color, let lineWidth):
                context.canvas.strokePath(path, in: rect, color: color, lineWidth: lineWidth)
            }
        }
        return [node]
    }

    private var authoredPoints: [Point] {
        elements.compactMap { element in
            switch element {
            case .move(let point), .line(let point):
                point
            case .closeSubpath:
                nil
            }
        }
    }
}

private struct PathLayout: NodeLayout {
    var path: Path

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        proposal.resolved(fallback: path.bounds?.size ?? Size(width: 10, height: 10))
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {}
}

private struct PathFitter {
    var source: Rect
    var destination: Rect

    init(source: Rect?, destination: Rect) {
        self.source = source ?? Rect(x: 0, y: 0, width: 1, height: 1)
        self.destination = destination
    }

    func callAsFunction(_ point: Point) -> Point {
        let scaleX = source.width > 0 ? destination.width / source.width : 1
        let scaleY = source.height > 0 ? destination.height / source.height : 1
        return Point(
            x: destination.x + (point.x - source.x) * scaleX,
            y: destination.y + (point.y - source.y) * scaleY
        )
    }
}
