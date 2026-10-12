import Foundation

/// Turns `ShapeGeometry` into interleaved `x, y, r, g, b, a` triangle vertices
/// in **logical space** (NDC conversion is `SceneCompiler`'s job). Pure — the
/// same output for the same input, testable without a GPU.
enum ShapeMesher {
    static func mesh(_ command: ShapeCommand) -> [Float] {
        let color = command.color.withAlpha(command.color.alpha * command.opacity)
        let t = command.transform
        var out: [Float] = []

        switch command.geometry {
        case .rect(let rect, let corner):
            appendRoundedRect(&out, rect, corner: corner, color: color, t: t)

        case .circle(let center, let radius):
            appendEllipse(&out, center: center, rx: radius, ry: radius, color: color, t: t)

        case .ellipse(let center, let rx, let ry):
            appendEllipse(&out, center: center, rx: rx, ry: ry, color: color, t: t)

        case .stroke(let points, let width, let closed):
            appendStroke(&out, points, width: width, closed: closed, color: color, t: t)

        case .polygon(let points):
            let tris = EarClipper.triangulate(points)
            var i = 0
            while i + 5 < tris.count {
                appendTri(&out,
                          RenderPoint(x: tris[i], y: tris[i + 1]),
                          RenderPoint(x: tris[i + 2], y: tris[i + 3]),
                          RenderPoint(x: tris[i + 4], y: tris[i + 5]),
                          color, color, color, t)
                i += 6
            }

        case .triangles(let xy):
            var i = 0
            while i + 5 < xy.count {
                appendTri(&out,
                          RenderPoint(x: xy[i], y: xy[i + 1]),
                          RenderPoint(x: xy[i + 2], y: xy[i + 3]),
                          RenderPoint(x: xy[i + 4], y: xy[i + 5]),
                          color, color, color, t)
                i += 6
            }

        case .verticalGradient(let rect, let top, let bottom):
            let tp = top.withAlpha(top.alpha * command.opacity)
            let bt = bottom.withAlpha(bottom.alpha * command.opacity)
            let p0 = RenderPoint(x: rect.x, y: rect.y)
            let p1 = RenderPoint(x: rect.x + rect.width, y: rect.y)
            let p2 = RenderPoint(x: rect.x + rect.width, y: rect.y + rect.height)
            let p3 = RenderPoint(x: rect.x, y: rect.y + rect.height)
            appendTri(&out, p0, p1, p2, tp, tp, bt, t)
            appendTri(&out, p0, p2, p3, tp, bt, bt, t)
        }
        return out
    }

    // MARK: primitives

    private static func segmentCount(for radius: Float, _ t: Transform2D) -> Int {
        let r = max(radius * t.approximateScale, 1)
        return min(max(Int((r * 0.7).squareRoot() * 3), 12), 96)
    }

    private static func appendEllipse(
        _ out: inout [Float], center: RenderPoint, rx: Float, ry: Float,
        color: RenderColor, t: Transform2D
    ) {
        let count = segmentCount(for: max(rx, ry), t)
        for i in 0..<count {
            let a = Float(i) / Float(count) * 2 * .pi
            let b = Float(i + 1) / Float(count) * 2 * .pi
            appendTri(&out, center,
                      RenderPoint(x: center.x + cos(a) * rx, y: center.y + sin(a) * ry),
                      RenderPoint(x: center.x + cos(b) * rx, y: center.y + sin(b) * ry),
                      color, color, color, t)
        }
    }

    private static func appendRoundedRect(
        _ out: inout [Float], _ rect: RenderRect, corner: Float,
        color: RenderColor, t: Transform2D
    ) {
        let r = min(max(corner, 0), min(rect.width, rect.height) * 0.5)
        func quad(_ x: Float, _ y: Float, _ w: Float, _ h: Float) {
            let p0 = RenderPoint(x: x, y: y)
            let p1 = RenderPoint(x: x + w, y: y)
            let p2 = RenderPoint(x: x + w, y: y + h)
            let p3 = RenderPoint(x: x, y: y + h)
            appendTri(&out, p0, p1, p2, color, color, color, t)
            appendTri(&out, p0, p2, p3, color, color, color, t)
        }
        guard r > 0 else { quad(rect.x, rect.y, rect.width, rect.height); return }
        quad(rect.x + r, rect.y, rect.width - 2 * r, rect.height)
        quad(rect.x, rect.y + r, r, rect.height - 2 * r)
        quad(rect.x + rect.width - r, rect.y + r, r, rect.height - 2 * r)
        let corners = [
            RenderPoint(x: rect.x + r, y: rect.y + r),
            RenderPoint(x: rect.x + rect.width - r, y: rect.y + r),
            RenderPoint(x: rect.x + rect.width - r, y: rect.y + rect.height - r),
            RenderPoint(x: rect.x + r, y: rect.y + rect.height - r),
        ]
        let starts: [Float] = [Float.pi, -.pi / 2, 0, .pi / 2]
        let seg = max(segmentCount(for: r, t) / 4, 3)
        for (center, start) in zip(corners, starts) {
            for i in 0..<seg {
                let a = start + Float(i) / Float(seg) * (.pi / 2)
                let b = start + Float(i + 1) / Float(seg) * (.pi / 2)
                appendTri(&out, center,
                          RenderPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r),
                          RenderPoint(x: center.x + cos(b) * r, y: center.y + sin(b) * r),
                          color, color, color, t)
            }
        }
    }

    /// A stroke is laid down without overlap, so a translucent colour has the same strength everywhere along it: each segment's
    /// quad shares its edge with the next one at a mitred join. Only a very sharp corner (past 120 degrees of turn) falls back to a
    /// round join, and an open line ends in a half disc; those are the only places pieces meet more than edge to edge.
    private static func appendStroke(
        _ out: inout [Float], _ points: [RenderPoint], width: Float, closed: Bool,
        color: RenderColor, t: Transform2D
    ) {
        var pts: [RenderPoint] = []
        for point in points {
            if let last = pts.last, abs(point.x - last.x) + abs(point.y - last.y) < 0.0001 { continue }
            pts.append(point)
        }
        if closed, pts.count > 1, let first = pts.first, let last = pts.last, abs(first.x - last.x) + abs(first.y - last.y) < 0.0001 {
            pts.removeLast()
        }
        guard pts.count >= 2 else { return }
        let hw = max(width, 0.5) * 0.5
        let count = pts.count
        let segments = closed ? count : count - 1

        // Unit direction of segment i, from pts[i] to pts[i + 1].
        func direction(_ i: Int) -> (x: Float, y: Float) {
            let from = pts[i], to = pts[(i + 1) % count]
            let dx = to.x - from.x, dy = to.y - from.y
            let len = max((dx * dx + dy * dy).squareRoot(), 0.0001)
            return (dx / len, dy / len)
        }

        // The offset (towards the left of travel) at vertex v for the segment that starts (or ends) there. A shared miter when both
        // neighbours exist and the turn is gentle; otherwise the segment's own normal, and the vertex needs a round join.
        var roundJoins: [Int] = []
        var shared = [(x: Float, y: Float)?](repeating: nil, count: count)
        for v in 0..<count {
            let before = closed ? (v - 1 + count) % count : (v > 0 ? v - 1 : nil)
            let after = closed ? v : (v < count - 1 ? v : nil)
            guard let before, let after else { continue }
            let d1 = direction(before), d2 = direction(after)
            let mx = -d1.y - d2.y, my = d1.x + d2.x
            let len2 = mx * mx + my * my
            // len2 = 4 cos^2(turn / 2); a miter longer than twice the half width is cut.
            if len2 >= 1 {
                let k = 2 * hw / len2
                shared[v] = (mx * k, my * k)
            } else {
                roundJoins.append(v)
            }
        }

        func offset(at v: Int, segment i: Int) -> (x: Float, y: Float) {
            if let miter = shared[v] { return miter }
            let d = direction(i)
            return (-d.y * hw, d.x * hw)
        }

        for i in 0..<segments {
            let v = i, w = (i + 1) % count
            let from = pts[v], to = pts[w]
            let start = offset(at: v, segment: i), end = offset(at: w, segment: i)
            let a = RenderPoint(x: from.x + start.x, y: from.y + start.y)
            let b = RenderPoint(x: to.x + end.x, y: to.y + end.y)
            let c = RenderPoint(x: to.x - end.x, y: to.y - end.y)
            let d = RenderPoint(x: from.x - start.x, y: from.y - start.y)
            appendTri(&out, a, b, c, color, color, color, t)
            appendTri(&out, a, c, d, color, color, color, t)
        }

        for v in roundJoins {
            appendEllipse(&out, center: pts[v], rx: hw, ry: hw, color: color, t: t)
        }

        if !closed {
            appendCap(&out, at: pts[0], direction: direction(0), halfWidth: hw, atStart: true, color: color, t: t)
            appendCap(&out, at: pts[count - 1], direction: direction(count - 2), halfWidth: hw, atStart: false, color: color, t: t)
        }
    }

    /// A half disc closing the end of an open stroke, on the outer side of its last quad only.
    private static func appendCap(
        _ out: inout [Float], at point: RenderPoint, direction d: (x: Float, y: Float), halfWidth hw: Float,
        atStart: Bool, color: RenderColor, t: Transform2D
    ) {
        let steps = max(segmentCount(for: hw, t) / 2, 4)
        let base = atan2(d.x, -d.y)
        let sweep: Float = atStart ? .pi : -.pi
        for i in 0..<steps {
            let a = base + sweep * Float(i) / Float(steps)
            let b = base + sweep * Float(i + 1) / Float(steps)
            appendTri(&out, point,
                      RenderPoint(x: point.x + cos(a) * hw, y: point.y + sin(a) * hw),
                      RenderPoint(x: point.x + cos(b) * hw, y: point.y + sin(b) * hw),
                      color, color, color, t)
        }
    }

    private static func appendTri(
        _ out: inout [Float],
        _ a: RenderPoint, _ b: RenderPoint, _ c: RenderPoint,
        _ ca: RenderColor, _ cb: RenderColor, _ cc: RenderColor,
        _ t: Transform2D
    ) {
        appendVertex(&out, t.apply(a), ca)
        appendVertex(&out, t.apply(b), cb)
        appendVertex(&out, t.apply(c), cc)
    }

    private static func appendVertex(_ out: inout [Float], _ p: RenderPoint, _ c: RenderColor) {
        out.append(p.x); out.append(p.y)
        out.append(c.red); out.append(c.green); out.append(c.blue); out.append(c.alpha)
    }
}
