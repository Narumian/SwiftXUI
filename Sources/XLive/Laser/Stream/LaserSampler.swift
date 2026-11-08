import Foundation
import simd

/// Spaces scanner samples for the galvanometers, as Legacy's `SEND` did. Two
/// ordinary drawing samples closer than `minimumStep` are merged into one; a longer
/// move between two samples is filled in with evenly spaced ones, at most `maximumStep`
/// apart, so the scanner is never asked to jump further than it can follow while
/// the light is on. A move between two samples that are not both ordinary (dwell or
/// blank) is left as a single jump, since those are placed where the scanner is
/// meant to settle.
public struct LaserSampler: LaserStage {
    /// Distances are in scanner units (the full width is 2).
    public var minimumStep: Double
    public var maximumStep: Double
    /// Most samples one move may be filled with.
    public var maximumInserted: Int
    private var previous: LaserPoint?

    public init(minimumStep: Double = 0, maximumStep: Double, maximumInserted: Int = 30000) {
        self.minimumStep = max(0, minimumStep)
        self.maximumStep = max(1e-9, maximumStep)
        self.maximumInserted = max(0, maximumInserted)
    }

    /// Forgets the previous sample; the next one is passed through as it is.
    public mutating func reset() { previous = nil }

    public mutating func process(_ chunk: LaserChunk<LaserPoint>) -> LaserChunk<LaserPoint> {
        var out: [LaserPoint] = []
        out.reserveCapacity(chunk.count)
        var starts = [Int](repeating: 0, count: chunk.count + 1)
        for (index, point) in chunk.elements.enumerated() {
            starts[index] = out.count
            guard let last = previous else { out.append(point); previous = point; continue }
            if point.mode == .normal, last.mode == .normal, Self.distance(last, point) < minimumStep { continue }
            out.append(contentsOf: filled(from: last, to: point))
            previous = point
        }
        starts[chunk.count] = out.count
        return LaserChunk(elements: out, carrying: chunk, starts: starts)
    }

    private static func distance(_ a: LaserPoint, _ b: LaserPoint) -> Double {
        Double(simd_distance(a.xy, b.xy))
    }

    /// The samples after `from` that lead to `to`, ending with `to`.
    private func filled(from: LaserPoint, to: LaserPoint) -> [LaserPoint] {
        if from.mode != .normal, to.mode != .normal { return [to] }
        let length = Self.distance(from, to)
        let inserted = min(maximumInserted, Int((length / maximumStep).rounded(.down)))
        guard inserted > 0 else { return [to] }
        let step = 1 / Float(inserted + 1)
        var points: [LaserPoint] = []
        points.reserveCapacity(inserted + 1)
        for i in 1...inserted {
            let t = step * Float(i)
            // The ends are in range, but rounding can leave a mix one step outside.
            let xy = simd_clamp(from.xy + (to.xy - from.xy) * t, SIMD2(repeating: -1), SIMD2(repeating: 1))
            let rgb = simd_clamp(from.rgb + (to.rgb - from.rgb) * t, .zero, SIMD3(repeating: 1))
            points.append(try! LaserPoint(xy: xy, rgb: rgb))
        }
        points.append(to)
        return points
    }
}
