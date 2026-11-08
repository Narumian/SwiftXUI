import Foundation
import simd

/// Holds the scanner on a corner so it can be drawn sharp. A galvanometer cannot
/// turn instantly: given one sample at a corner it rounds the corner off or
/// overshoots it. This adds dwell samples after each drawn vertex where the path
/// turns by more than `thresholdDegrees`, more of them the sharper the turn, up to
/// `maximum` for a full reversal.
///
/// It belongs in the output chain, after projection and before the sampler: the
/// angle that matters is the one the scanner sees, and how much hold a corner needs
/// depends on the scanner, not on the shape. A shape that wants a hold regardless
/// can mark the vertex `dwell` itself; those, and vertices that already have a dwell
/// right after them, are left alone. The first and last vertex of a shape are not
/// corners here (`LaserDwellBlank` holds the ends), nor is any vertex next to a
/// blank one.
///
/// Like `LaserDwellBlank` it takes every run in a chunk to be a whole shape.
public struct LaserCornerDwell: LaserStage {
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

    public mutating func process(_ chunk: LaserChunk<LaserPoint>) -> LaserChunk<LaserPoint> {
        guard maximum > 0, chunk.count >= 3 else { return chunk }
        let runs = chunk.runs.isEmpty ? [LaserRun(id: 0, range: 0..<chunk.count)] : chunk.wellFormedRuns
        var extra = [Int](repeating: 0, count: chunk.count)
        var any = false
        for run in runs where run.range.count >= 3 {
            for index in (run.range.lowerBound + 1)..<(run.range.upperBound - 1) {
                let held = dwell(before: chunk.elements[index - 1], at: chunk.elements[index], after: chunk.elements[index + 1])
                if held > 0 { extra[index] = held; any = true }
            }
        }
        guard any else { return chunk }

        var out: [LaserPoint] = []
        out.reserveCapacity(chunk.count + extra.reduce(0, +))
        var starts = [Int](repeating: 0, count: chunk.count + 1)
        for (index, point) in chunk.elements.enumerated() {
            starts[index] = out.count
            out.append(point)
            if extra[index] > 0 { out.append(contentsOf: Array(repeating: point.dwelling(), count: extra[index])) }
        }
        starts[chunk.count] = out.count
        return LaserChunk(elements: out, carrying: chunk, starts: starts)
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
