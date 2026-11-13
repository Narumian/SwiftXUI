import Foundation

/// Small symbols drawn as shapes, for the ones a font does not reliably carry (a bundled UI font often has no
/// "✕" or round arrows). The symbol is a square of `size`, painted in `color`; sizing, padding and the tap
/// gesture are the caller's, as for any view.
///
/// ```swift
/// XIcon(.close, size: 14, color: .white).padding(8).onTapGesture(id: "close", label: "Close") { ... }
/// ```
public struct XIcon: XView {
    public enum Kind: Hashable, Sendable {
        /// A cross, for closing a sheet or removing an item.
        case close
        /// A round arrow turning back.
        case undo
        /// A round arrow turning forward: `undo` mirrored left to right.
        case redo
        /// An almost closed round arrow, for starting again.
        case reload
        /// A filled triangle pointing right.
        case play
        /// A filled square.
        case stop
        /// Three dots in a row, for a menu of more.
        case more
        /// A chevron pointing up, for a section that opens upward or is open.
        case chevronUp
        /// A chevron pointing down.
        case chevronDown
    }

    public var kind: Kind
    public var size: Double
    public var color: XColorValue
    public var lineWidth: Double

    public init(_ kind: Kind, size: Double = 16, color: XColorValue = .white, lineWidth: Double = 2) {
        self.kind = kind; self.size = size; self.color = color; self.lineWidth = lineWidth
    }

    public var body: some XView {
        let kind = kind, color = color, lineWidth = lineWidth
        return DrawLayer(size: { [size] _ in Size(width: size, height: size) }) { rect, context in
            let canvas = context.canvas
            switch kind {
            case .close:
                XIcon.stroke(canvas, [Point(x: rect.x + rect.width * 0.1, y: rect.y + rect.height * 0.1),
                                      Point(x: rect.x + rect.width * 0.9, y: rect.y + rect.height * 0.9)], color, lineWidth)
                XIcon.stroke(canvas, [Point(x: rect.x + rect.width * 0.9, y: rect.y + rect.height * 0.1),
                                      Point(x: rect.x + rect.width * 0.1, y: rect.y + rect.height * 0.9)], color, lineWidth)
            case .undo, .redo:
                XIcon.drawTurningArrow(canvas, in: rect, mirrored: kind == .redo, sweep: 200, color, lineWidth)
            case .reload:
                XIcon.drawTurningArrow(canvas, in: rect, mirrored: false, sweep: 280, color, lineWidth)
            case .play:
                XIcon.fill(canvas, in: rect, [(0.22, 0.1), (0.9, 0.5), (0.22, 0.9)], color)
            case .stop:
                XIcon.fill(canvas, in: rect, [(0.15, 0.15), (0.85, 0.15), (0.85, 0.85), (0.15, 0.85)], color)
            case .more:
                for cx in [0.15, 0.5, 0.85] {
                    let dot = stride(from: 0.0, to: 360.0, by: 45.0).map { a -> (Double, Double) in
                        (cx + 0.12 * cos(a * .pi / 180), 0.5 + 0.12 * sin(a * .pi / 180))
                    }
                    XIcon.fill(canvas, in: rect, dot, color)
                }
            case .chevronUp:
                XIcon.stroke(canvas, [XIcon.point(in: rect, 0.12, 0.68), XIcon.point(in: rect, 0.5, 0.3), XIcon.point(in: rect, 0.88, 0.68)], color, lineWidth)
            case .chevronDown:
                XIcon.stroke(canvas, [XIcon.point(in: rect, 0.12, 0.32), XIcon.point(in: rect, 0.5, 0.7), XIcon.point(in: rect, 0.88, 0.32)], color, lineWidth)
            }
        }
    }

    /// A path is stretched to fill the rect it is drawn in, so each one is drawn in its own bounds.
    private static func bounds(_ points: [Point]) -> Rect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let (minX, maxX, minY, maxY) = (xs.min() ?? 0, xs.max() ?? 0, ys.min() ?? 0, ys.max() ?? 0)
        return Rect(x: minX, y: minY, width: max(0.01, maxX - minX), height: max(0.01, maxY - minY))
    }

    private static func point(in rect: Rect, _ x: Double, _ y: Double) -> Point {
        Point(x: rect.x + x * rect.width, y: rect.y + y * rect.height)
    }

    private static func fill(_ canvas: any XCanvas, in rect: Rect, _ unit: [(Double, Double)], _ color: XColorValue) {
        let points = unit.map { point(in: rect, $0.0, $0.1) }
        canvas.fillPath(Path(points: points), in: bounds(points), color: color)
    }

    private static func stroke(_ canvas: any XCanvas, _ points: [Point], _ color: XColorValue, _ lineWidth: Double) {
        canvas.strokePath(Path(points: points, closed: false), in: bounds(points), color: color, lineWidth: lineWidth)
    }

    /// An arc that runs from the lower right over the top to the upper left, ending in the head (undo); mirrored for
    /// redo. `sweep` is how many degrees the arc turns: 200 for a step back, 280 for starting again.
    private static func drawTurningArrow(_ canvas: any XCanvas, in rect: Rect, mirrored: Bool, sweep: Double, _ color: XColorValue, _ lineWidth: Double) {
        func place(_ x: Double, _ y: Double) -> Point {
            Point(x: rect.x + (mirrored ? 1 - x : x) * rect.width, y: rect.y + y * rect.height)
        }
        let cx = 0.5, cy = 0.6, radius = 0.34
        let arc = stride(from: 150.0, through: 150.0 - sweep, by: -12.5).map { a -> Point in
            let r = a * .pi / 180
            return place(cx + radius * cos(r), cy - radius * sin(r))
        }
        stroke(canvas, arc, color, lineWidth)
        // The head sits on the start of the arc and points the way the arc would go on (counter-clockwise).
        let r = 150.0 * .pi / 180
        let px = cx + radius * cos(r), py = cy - radius * sin(r)
        let dx = -sin(r), dy = -cos(r), nx = -dy, ny = dx
        let tip = place(px + dx * 0.14, py + dy * 0.14)
        let back = (x: px - dx * 0.06, y: py - dy * 0.06)
        let head = [tip, place(back.x + nx * 0.2, back.y + ny * 0.2), place(back.x - nx * 0.2, back.y - ny * 0.2)]
        canvas.fillPath(Path(points: head), in: bounds(head), color: color)
    }
}
