import Foundation

/// Monoline vector font → triangle vertices in logical space. Ported from the
/// old `Canvas.text`; kept until an SDF glyph atlas replaces it.
public enum TextMesher {
    public static func width(_ text: String, scale: Float) -> Float {
        guard !text.isEmpty else { return 0 }
        return Float(text.count) * 6 * scale - scale
    }

    public static func mesh(_ command: TextCommand) -> [Float] {
        let scale = command.scale
        let color = command.color
        let startX = command.centeredWidth.map {
            command.origin.x + ($0 - width(command.string, scale: scale)) * 0.5
        } ?? command.origin.x
        // VectorFont's own glyphs are fixed to a 0...7 local Y span (see the
        // path data below), so their ink center is always exactly 3.5 — this
        // mirrors the atlas path's real-ink-bounds centering with VectorFont's
        // own known metric instead of a measured one.
        let originY = command.centeredHeight.map { command.origin.y + $0 * 0.5 - 3.5 * scale } ?? command.origin.y

        var out: [Float] = []
        var cursor = startX
        let stroke = scale * 0.72
        for character in command.string.uppercased() {
            for path in VectorFont.paths(for: character) {
                let points = path.map {
                    RenderPoint(x: cursor + $0.0 * scale, y: originY + $0.1 * scale)
                }
                for i in points.indices.dropFirst() {
                    appendStrokeSegment(&out, points[i - 1], points[i], width: stroke, color: color, t: command.transform)
                }
                for point in points {
                    appendDot(&out, point, radius: stroke * 0.5, color: color, t: command.transform)
                }
            }
            cursor += 6 * scale
        }
        return out
    }

    private static func appendStrokeSegment(
        _ out: inout [Float], _ from: RenderPoint, _ to: RenderPoint,
        width: Float, color: RenderColor, t: Transform2D
    ) {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = max((dx * dx + dy * dy).squareRoot(), 0.0001)
        let nx = -dy / len * width * 0.5, ny = dx / len * width * 0.5
        let a = RenderPoint(x: from.x + nx, y: from.y + ny)
        let b = RenderPoint(x: to.x + nx, y: to.y + ny)
        let c = RenderPoint(x: to.x - nx, y: to.y - ny)
        let d = RenderPoint(x: from.x - nx, y: from.y - ny)
        tri(&out, a, b, c, color, t); tri(&out, a, c, d, color, t)
    }

    private static func appendDot(
        _ out: inout [Float], _ center: RenderPoint, radius: Float,
        color: RenderColor, t: Transform2D
    ) {
        let seg = 8
        for i in 0..<seg {
            let a = Float(i) / Float(seg) * 2 * .pi
            let b = Float(i + 1) / Float(seg) * 2 * .pi
            tri(&out, center,
                RenderPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius),
                RenderPoint(x: center.x + cos(b) * radius, y: center.y + sin(b) * radius),
                color, t)
        }
    }

    private static func tri(
        _ out: inout [Float], _ a: RenderPoint, _ b: RenderPoint, _ c: RenderPoint,
        _ color: RenderColor, _ t: Transform2D
    ) {
        for p in [t.apply(a), t.apply(b), t.apply(c)] {
            out.append(p.x); out.append(p.y)
            out.append(color.red); out.append(color.green); out.append(color.blue); out.append(color.alpha)
        }
    }
}
