import Foundation

public struct MaskPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

public struct LaserMask: Codable, Equatable, Sendable, Identifiable {
    public enum Shape: String, Codable, Sendable { case polygon, ellipse }
    public var id: UUID = UUID()
    public var shape: Shape
    /// Coordinates in the full normalized output area, origin at top left.
    public var points: [MaskPoint]
    public var softEdge: Double = 0
    public var dimmer: Double = 0
    public var enabled: Bool = true

    public static func make(_ shape: Shape) -> LaserMask {
        switch shape {
        case .polygon: LaserMask(shape: shape, points: [.init(0.2, 0.3), .init(0.8, 0.3), .init(0.8, 0.7), .init(0.2, 0.7)])
        case .ellipse: LaserMask(shape: shape, points: [.init(0.25, 0.3), .init(0.75, 0.7)])
        }
    }

    /// Returns the light multiplier, with softEdge measured as a fraction of
    /// the full output width. Multiple masks multiply their contributions.
    public func multiplier(at p: MaskPoint) -> Double {
        guard enabled else { return 1 }
        let distance: Double
        switch shape {
        case .polygon:
            guard points.count >= 3 else { return 1 }
            var inside = false
            var edgeDistance = Double.infinity
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % points.count]
                if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                let dx = b.x - a.x, dy = b.y - a.y
                let length = dx * dx + dy * dy
                let t = length > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
                edgeDistance = min(edgeDistance, hypot(p.x - a.x - t * dx, p.y - a.y - t * dy))
            }
            guard inside else { return 1 }
            distance = edgeDistance
        case .ellipse:
            guard points.count == 2 else { return 1 }
            let a = points[0], b = points[1]
            let rx = abs(b.x - a.x) / 2, ry = abs(b.y - a.y) / 2
            guard rx > 0, ry > 0 else { return 1 }
            let r = hypot((p.x - (a.x + b.x) / 2) / rx, (p.y - (a.y + b.y) / 2) / ry)
            guard r <= 1 else { return 1 }
            distance = (1 - r) * min(rx, ry)
        }
        let amount = softEdge > 0 ? min(1, max(0, distance / softEdge)) : 1
        return 1 - (1 - min(1, max(0, dimmer))) * amount
    }
}

public struct LaserMaskSettings: Codable, Equatable, Sendable {
    public var masks: [LaserMask] = []
    public init(masks: [LaserMask] = []) { self.masks = masks }
    public func multiplier(at point: MaskPoint) -> Double { masks.reduce(1) { $0 * $1.multiplier(at: point) } }
}
