import Foundation
import simd

/// Holds the scanner on a corner so it can be drawn sharp. A galvanometer cannot
/// turn instantly: given one sample at a corner it rounds the corner off or
/// overshoots it. This adds dwell samples after each drawn vertex where the path
/// turns by more than `thresholdDegrees`, more of them the sharper the turn, up to
/// `maximum` for a full reversal.
///
/// It belongs in the back half, after projection and before the resampler: the
/// angle that matters is the one the scanner sees, and how much hold a corner needs
/// depends on the scanner, not on the shape. A shape that wants a hold regardless
/// can mark the vertex `dwell` itself; those, and vertices that already have a dwell
/// right after them, are left alone. The first and last vertex of a shape are not
/// corners here (`LaserDwellBlank` holds the ends), nor is any vertex next to a
/// blank one.
///
/// It looks at each shape on its own.
public struct LaserCornerDwell: Sendable {
    /// Dwell samples for a turn all the way back on itself. Zero turns the stage off.
    public var maximum: Int
    public var thresholdDegrees: Double
    /// Edges shorter than this (scanner units) have no direction and are ignored.
    public var minimumLength: Double

    public init(maximum: Int, thresholdDegrees: Double = 20, minimumLength: Double = 1e-4) {
        self.maximum = max(0, maximum)
        self.thresholdDegrees = min(180, max(0, thresholdDegrees))
        self.minimumLength = max(0, minimumLength)
    }

    public mutating func process(_ shapes: [Laser2DShape]) -> [Laser2DShape] {
        guard maximum > 0 else { return shapes }
        return shapes.map { shape in
            let points = shape.points
            guard points.count >= 3 else { return shape }
            var out: [LaserPoint] = []
            out.reserveCapacity(points.count)
            out.append(points[0])
            for index in 1..<(points.count - 1) {
                out.append(points[index])
                let held = dwell(before: points[index - 1], at: points[index], after: points[index + 1])
                if held > 0 { out.append(contentsOf: Array(repeating: points[index].dwelling(), count: held)) }
            }
            out.append(points[points.count - 1])
            return Laser2DShape(id: shape.id, points: out)
        }
    }

    /// How many dwell samples the vertex `point` needs between its neighbours.
    private func dwell(before a: LaserPoint, at point: LaserPoint, after b: LaserPoint) -> Int {
        guard point.mode == .normal, !a.isBlanked, !b.isBlanked else { return 0 }
        let incoming = SIMD2<Double>(point.xy - a.xy), outgoing = SIMD2<Double>(b.xy - point.xy)
        let inLength = simd_length(incoming), outLength = simd_length(outgoing)
        guard inLength >= minimumLength, outLength >= minimumLength else { return 0 }
        let cosine = min(1, max(-1, simd_dot(incoming, outgoing) / (inLength * outLength)))
        let turn = acos(cosine) * 180 / .pi
        guard turn >= thresholdDegrees else { return 0 }
        return max(1, Int((turn / 180 * Double(maximum)).rounded()))
    }
}
