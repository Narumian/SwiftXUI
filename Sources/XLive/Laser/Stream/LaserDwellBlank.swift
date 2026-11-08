import Foundation

/// Gives every shape the settling time a scanner needs at its ends: before the
/// first vertex, blank then dwell samples at its position; after the last, dwell
/// samples and one blank. This is Legacy's `dwellBlankInserted`, applied per shape
/// run. A vertex that is not a normal drawing vertex gets no padding at that end,
/// and a chunk without runs is treated as one shape.
public struct LaserDwellBlank: LaserStage {
    public var dwell: Int
    public var blank: Int

    public init(dwell: Int, blank: Int) { self.dwell = max(0, dwell); self.blank = max(0, blank) }

    public mutating func process(_ chunk: LaserChunk<LaserVertex>) -> LaserChunk<LaserVertex> {
        guard dwell > 0 || blank > 0, !chunk.isEmpty else { return chunk }
        let runs = chunk.runs.isEmpty ? [LaserRun(id: 0, range: 0..<chunk.count)] : chunk.runs
        var out: [LaserVertex] = []
        out.reserveCapacity(chunk.count + runs.count * (2 * dwell + 2 * blank))
        var starts = [Int](repeating: 0, count: chunk.count + 1)
        var cursor = 0

        func copy(upTo end: Int) {
            while cursor < end { starts[cursor] = out.count; out.append(chunk.elements[cursor]); cursor += 1 }
        }
        for run in runs where !run.range.isEmpty {
            copy(upTo: run.range.lowerBound)
            let first = chunk.elements[run.range.lowerBound], last = chunk.elements[run.range.upperBound - 1]
            starts[run.range.lowerBound] = out.count
            if first.mode == .normal {
                out.append(contentsOf: Array(repeating: first.blanked(), count: blank))
                out.append(contentsOf: Array(repeating: first.dwelling(), count: dwell))
            }
            for index in run.range {
                if index > run.range.lowerBound { starts[index] = out.count }
                out.append(chunk.elements[index])
            }
            if last.mode == .normal {
                out.append(contentsOf: Array(repeating: last.dwelling(), count: dwell))
                out.append(contentsOf: Array(repeating: last.blanked(), count: min(blank, 1)))
            }
            cursor = run.range.upperBound
        }
        copy(upTo: chunk.count)
        // A run ends where its padding ends, which is where the next run or gap element
        // begins; both were recorded above, so only the very end is left.
        starts[chunk.count] = out.count
        return LaserChunk(elements: out, carrying: chunk, starts: starts)
    }
}
