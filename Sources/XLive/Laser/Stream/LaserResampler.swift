import Foundation
import simd

/// Spaces scanner samples for the galvanometers. This is Legacy's `SEND` taken as it
/// was, run over each shape in turn:
///
/// - **Clip.** A drawn sample closer than `minimumStep` to the previous one (both
///   normal) is dropped, and the previous one stays where it was. (`clipRate`.)
/// - **Interpolate.** The move from the previous sample to this one is filled in with
///   evenly spaced samples, `floor(length / maximumStep)` of them (at most
///   `maximumInserted`), their colour mixed between the two ends, each a normal sample;
///   then this sample itself. A move between two samples that are both not normal
///   (dwell or blank) is a single jump. (`LSPoint.interpolate`.)
///
/// As in Legacy, a move shorter than one step comes out as the sample twice (the
/// interpolation gives `[dst]` and the caller adds `dst` again), and the very first
/// move starts from a dark sample at the centre. The previous sample is carried from
/// one shape, and one read, to the next, so the move from a shape's last sample to
/// the next shape's first is filled in too, and belongs to the next shape.
public struct LaserResampler: Sendable {
    /// Distances are in scanner units (the full width is 2).
    public var minimumStep: Double
    public var maximumStep: Double
    /// Most samples one move may be filled with.
    public var maximumInserted: Int
    private var previous = try! LaserPoint(xy: .zero, rgb: .zero)

    public init(minimumStep: Double = 0, maximumStep: Double, maximumInserted: Int = 30000) {
        self.minimumStep = max(0, minimumStep)
        self.maximumStep = max(1e-9, maximumStep)
        self.maximumInserted = max(0, maximumInserted)
    }

    /// Goes back to the dark centre sample Legacy starts from.
    public mutating func reset() { previous = try! LaserPoint(xy: .zero, rgb: .zero) }

    public mutating func process(_ shapes: [Laser2DShape]) -> [Laser2DShape] {
        var out: [Laser2DShape] = []
        out.reserveCapacity(shapes.count)
        for shape in shapes {
            var points: [LaserPoint] = []
            points.reserveCapacity(shape.points.count)
            for point in shape.points {
                if point.mode == .normal, previous.mode == .normal, Self.distance(previous, point) < minimumStep { continue }
                points.append(contentsOf: interpolated(from: previous, to: point))
                previous = point
            }
            if !points.isEmpty { out.append(Laser2DShape(id: shape.id, points: points)) }
        }
        return out
    }

    private static func distance(_ a: LaserPoint, _ b: LaserPoint) -> Double {
        simd_length(SIMD2<Double>(a.xy) - SIMD2<Double>(b.xy))
    }

    /// Legacy's `LSPoint.interpolate(to:rate:maxCount:)`.
    private func interpolated(from: LaserPoint, to: LaserPoint) -> [LaserPoint] {
        if from.mode != .normal, to.mode != .normal { return [to] }
        let length = Self.distance(from, to)
        let iteration = min(maximumInserted, Int(min(floor(length / max(maximumStep, Double.ulpOfOne)), Double(Int.max))))
        var inter: [LaserPoint] = []
        if iteration > 0 {
            let step = 1 / Double(iteration + 1)
            let st = SIMD2<Double>(from.xy), ed = SIMD2<Double>(to.xy)
            let stl = SIMD3<Double>(from.rgb), edl = SIMD3<Double>(to.rgb)
            inter.reserveCapacity(iteration + 2)
            for i in 1...iteration {
                let t = step * Double(i)
                // The ends are in range, but rounding can leave a mix one step outside.
                let xy = simd_clamp(SIMD2<Float>(st + (ed - st) * t), SIMD2(repeating: -1), SIMD2(repeating: 1))
                let rgb = simd_clamp(SIMD3<Float>(stl + (edl - stl) * t), .zero, SIMD3(repeating: 1))
                inter.append(try! LaserPoint(xy: xy, rgb: rgb))
            }
        } else {
            inter = [to]
        }
        return inter + [to]
    }
}
