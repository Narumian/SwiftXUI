import Foundation

public struct LaserDwellBlank: Sendable {
    public var dwell: Int
    public var blank: Int

    public init(dwell: Int, blank: Int) { self.dwell = max(0, dwell); self.blank = max(0, blank) }

    public mutating func process(_ shapes: [Laser2DShape]) -> [Laser2DShape] {
        guard dwell > 0 || blank > 0 else { return shapes }
        return shapes.map { shape in
            guard let first = shape.points.first, let last = shape.points.last else { return shape }
            let FD = first.mode == .normal ? dwell : 0
            let FB = first.mode == .normal ? blank : 0
            let LD = last.mode == .normal ? dwell : 0
            let leadingBlank = Array(repeating: first.blanked(), count: FB)
            let leadingDwell = Array(repeating: first.dwelling(), count: FD)
            let trailingDwell = Array(repeating: last.dwelling(), count: LD)
            return Laser2DShape(id: shape.id, points: leadingBlank + leadingDwell + shape.points + trailingDwell)
        }
    }
}
