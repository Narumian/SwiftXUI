import Foundation

/// Triangulates a simple polygon (no self-intersections, no holes) by ear
/// clipping. Robust enough for hand-authored character silhouettes; the
/// offline `rigged-mesh` tool bridges holes into a single ring before calling.
enum EarClipper {
    /// Returns flat triangle vertices `[x0,y0, x1,y1, x2,y2, ...]`. Empty on
    /// degenerate input.
    static func triangulate(_ polygon: [RenderPoint]) -> [Float] {
        guard polygon.count >= 3 else { return [] }
        var indices = Array(0..<polygon.count)
        if signedArea(polygon, indices) < 0 { indices.reverse() }  // want CCW

        var out: [Float] = []
        out.reserveCapacity((polygon.count - 2) * 6)
        var guardCounter = 0
        let limit = polygon.count * polygon.count + 16

        while indices.count > 3 {
            guardCounter += 1
            if guardCounter > limit { break }
            var clipped = false
            let n = indices.count
            for i in 0..<n {
                let i0 = indices[(i + n - 1) % n]
                let i1 = indices[i]
                let i2 = indices[(i + 1) % n]
                let a = polygon[i0], b = polygon[i1], c = polygon[i2]
                if cross(a, b, c) <= 0 { continue }        // reflex or collinear
                if anyPointInside(polygon, indices, exclude: [i0, i1, i2], a, b, c) { continue }
                out.append(contentsOf: [a.x, a.y, b.x, b.y, c.x, c.y])
                indices.remove(at: i)
                clipped = true
                break
            }
            if !clipped { break }   // fan-fallback below
        }
        if indices.count == 3 {
            let a = polygon[indices[0]], b = polygon[indices[1]], c = polygon[indices[2]]
            out.append(contentsOf: [a.x, a.y, b.x, b.y, c.x, c.y])
        } else if indices.count > 3 {
            // Degenerate leftover — fan it so nothing silently vanishes.
            for i in 1..<(indices.count - 1) {
                let a = polygon[indices[0]], b = polygon[indices[i]], c = polygon[indices[i + 1]]
                out.append(contentsOf: [a.x, a.y, b.x, b.y, c.x, c.y])
            }
        }
        return out
    }

    private static func cross(_ a: RenderPoint, _ b: RenderPoint, _ c: RenderPoint) -> Float {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func signedArea(_ p: [RenderPoint], _ idx: [Int]) -> Float {
        var sum: Float = 0
        for i in 0..<idx.count {
            let a = p[idx[i]], b = p[idx[(i + 1) % idx.count]]
            sum += a.x * b.y - b.x * a.y
        }
        return sum * 0.5
    }

    private static func anyPointInside(
        _ polygon: [RenderPoint], _ indices: [Int], exclude: [Int],
        _ a: RenderPoint, _ b: RenderPoint, _ c: RenderPoint
    ) -> Bool {
        for idx in indices where !exclude.contains(idx) {
            if pointInTriangle(polygon[idx], a, b, c) { return true }
        }
        return false
    }

    private static func pointInTriangle(_ p: RenderPoint, _ a: RenderPoint, _ b: RenderPoint, _ c: RenderPoint) -> Bool {
        let d1 = cross(a, b, p), d2 = cross(b, c, p), d3 = cross(c, a, p)
        let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
        let hasPos = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNeg && hasPos)
    }
}
