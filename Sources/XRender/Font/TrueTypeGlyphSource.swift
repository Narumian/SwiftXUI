import Foundation

/// Exact-area coverage rasteriser for closed polygons (the "signed area
/// accumulation" scanline method). Deterministic and platform-independent.
public enum OutlineRasterizer {
    public struct Segment: Sendable {
        public var x0: Float, y0: Float, x1: Float, y1: Float
        public init(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) {
            self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
        }
    }

    /// `segments` are in bitmap space (x right, y **down**, origin at the
    /// bitmap's top-left). Returns `width * height` coverage, 0...255. Winding is
    /// non-zero: overlapping same-direction contours saturate instead of
    /// cancelling, which is what glyphs with overlapping strokes need.
    public static func coverage(_ segments: [Segment], width: Int, height: Int) -> [UInt8] {
        guard width > 0, height > 0 else { return [] }
        let stride = width + 2
        var acc = [Float](repeating: 0, count: stride * height + 2)
        for s in segments {
            guard s.y0 != s.y1 else { continue }
            let dir: Float = s.y0 < s.y1 ? 1 : -1
            let (ax, ay, bx, by) = s.y0 < s.y1 ? (s.x0, s.y0, s.x1, s.y1) : (s.x1, s.y1, s.x0, s.y0)
            let dxdy = (bx - ax) / (by - ay)
            var x = ax
            if ay < 0 { x -= ay * dxdy }
            let firstRow = max(0, Int(ay))
            let lastRow = min(height, Int(by.rounded(.up)))
            guard firstRow < lastRow else { continue }
            for y in firstRow..<lastRow {
                let rowStart = y * stride
                let dy = min(Float(y + 1), by) - max(Float(y), ay)
                let xNext = x + dxdy * dy
                let d = dy * dir
                let (x0, x1) = x < xNext ? (x, xNext) : (xNext, x)
                let x0floor = x0.rounded(.down)
                let x0i = Int(x0floor)
                let x1ceil = x1.rounded(.up)
                let x1i = Int(x1ceil)
                if x0i >= 0 && x1i <= width + 1 {
                    if x1i <= x0i + 1 {
                        let xmf = 0.5 * (x + xNext) - x0floor
                        acc[rowStart + x0i] += d - d * xmf
                        acc[rowStart + x0i + 1] += d * xmf
                    } else {
                        let s = 1 / (x1 - x0)
                        let x0f = x0 - x0floor
                        let a0 = 0.5 * s * (1 - x0f) * (1 - x0f)
                        let x1f = x1 - x1ceil + 1
                        let am = 0.5 * s * x1f * x1f
                        acc[rowStart + x0i] += d * a0
                        if x1i == x0i + 2 {
                            acc[rowStart + x0i + 1] += d * (1 - a0 - am)
                        } else {
                            let a1 = s * (1.5 - x0f)
                            acc[rowStart + x0i + 1] += d * (a1 - a0)
                            if x0i + 2 < x1i - 1 {
                                for xi in (x0i + 2)..<(x1i - 1) { acc[rowStart + xi] += d * s }
                            }
                            let a2 = a1 + Float(x1i - x0i - 3) * s
                            acc[rowStart + x1i - 1] += d * (1 - a2 - am)
                        }
                        acc[rowStart + x1i] += d * am
                    }
                }
                x = xNext
            }
        }
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            var sum: Float = 0
            for x in 0..<width {
                sum += acc[y * stride + x]
                out[y * width + x] = UInt8(min(1, abs(sum)) * 255 + 0.5)
            }
        }
        return out
    }
}

/// `GlyphRasterizer` backed by `TrueTypeFont` + `OutlineRasterizer`. Same output
/// on every platform. Glyphs are rasterised with the pen on an exact pixel
/// corner, so callers that place glyphs on whole pixels get repeatable stems.
public final class TrueTypeGlyphSource: GlyphRasterizer {
    /// Post-processing of the raw geometric coverage. Small text loses weight
    /// when it is rasterised without hinting; OS rasterisers compensate
    /// ("font smoothing" / stem darkening). `gamma > 1` lifts partial coverage
    /// toward full; `gain` scales it. Identity (1, 1) is the untouched geometry.
    public struct Tuning: Sendable, Equatable {
        public var gamma: Float
        public var gain: Float
        public init(gamma: Float = 1, gain: Float = 1) { self.gamma = gamma; self.gain = gain }
        public static let none = Tuning()
    }

    public let font: TrueTypeFont
    public let pixelSize: Float
    public let tuning: Tuning
    public let metrics: FontMetrics
    private let scale: Float
    /// Vertical "blue zone" snapping: the baseline, x-height, cap height and
    /// ascender are moved to whole pixels and the outline is stretched
    /// piecewise-linearly between them. Flat tops and bottoms then land on
    /// pixel rows instead of straddling two, which is most of what makes an
    /// OS rasteriser's small text look crisp. (source px, snapped px), ascending.
    private let zones: [(from: Float, to: Float)]

    public init(font: TrueTypeFont, pixelSize: Float, tuning: Tuning = .none, snapVertical: Bool = false) {
        self.font = font
        self.pixelSize = pixelSize
        self.tuning = tuning
        let scale = pixelSize / Float(font.unitsPerEm)
        self.scale = scale
        self.zones = snapVertical ? Self.blueZones(font, scale: scale) : []
        self.metrics = FontMetrics(
            ascent: Float(font.ascender) * scale,
            descent: Float(-font.descender) * scale,
            lineHeight: Float(font.ascender - font.descender + font.lineGap) * scale,
            capHeight: Float(font.capHeight) * scale)
    }

    public func rasterize(_ ch: Character) -> RasterizedGlyph? { render(ch, supersample: 1) }

    /// The same frame at `supersample`× resolution (for sub-pixel distance fields).
    public func rasterize(_ ch: Character, supersample: Int) -> RasterizedGlyph? {
        supersample > 1 ? render(ch, supersample: supersample) : render(ch, supersample: 1)
    }

    private func render(_ ch: Character, supersample k: Int) -> RasterizedGlyph? {
        guard ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first,
              let index = font.glyphIndex(for: scalar) else { return nil }
        let advance = Float(font.advance(glyph: index)) * scale
        let scaled = font.contours(glyph: index).map { contour in
            contour.map { TrueTypeFont.Point(x: $0.x * scale, y: snapY($0.y * scale), onCurve: $0.onCurve) }
        }
        var minX = Float.infinity, minY = Float.infinity, maxX = -Float.infinity, maxY = -Float.infinity
        for p in scaled.joined() {
            minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        guard minX.isFinite, maxX > minX, maxY > minY else {
            return RasterizedGlyph(coverage: [], width: 0, height: 0, advance: advance, left: 0, top: 0)
        }
        // Whole-pixel bitmap; (originX, originY) is its top-left in glyph space (y-up).
        let originX = minX.rounded(.down)
        let originY = maxY.rounded(.up)
        let width = Int(maxX.rounded(.up) - originX)
        let height = Int(originY - minY.rounded(.down))
        let kf = Float(k)
        var segments: [OutlineRasterizer.Segment] = []
        for contour in scaled {
            Self.flatten(contour) { a, b in
                segments.append(.init((a.x - originX) * kf, (originY - a.y) * kf, (b.x - originX) * kf, (originY - b.y) * kf))
            }
        }
        var coverage = OutlineRasterizer.coverage(segments, width: width * k, height: height * k)
        if k == 1, tuning != .none {
            for i in coverage.indices {
                let c = Float(coverage[i]) / 255
                coverage[i] = UInt8(min(1, pow(c, 1 / tuning.gamma) * tuning.gain) * 255 + 0.5)
            }
        }
        return RasterizedGlyph(coverage: coverage, width: width * k, height: height * k,
                               advance: advance, left: originX, top: originY)
    }

    // MARK: - Vertical snapping

    private static func blueZones(_ font: TrueTypeFont, scale: Float) -> [(from: Float, to: Float)] {
        func top(_ chars: String) -> Float? {
            var best: Float?
            for c in chars.unicodeScalars {
                guard let g = font.glyphIndex(for: c), let y = font.contours(glyph: g).joined().map(\.y).max() else { continue }
                best = max(best ?? y, y)
            }
            return best
        }
        var raw: [Float] = []
        if let xh = top("xzvw") { raw.append(xh) }
        if font.capHeight > 0 { raw.append(Float(font.capHeight)) }
        if let asc = top("bdhkl") { raw.append(asc) }
        var zones: [(from: Float, to: Float)] = [(0, 0)]
        for value in raw.sorted() {
            let from = value * scale, to = from.rounded()
            // keep zones distinct and in order; skip ones that would collapse or cross
            if let last = zones.last, from - last.from >= 1, to > last.to { zones.append((from, to)) }
        }
        return zones
    }

    private func snapY(_ y: Float) -> Float {
        guard zones.count > 1 else { return y }
        if y <= zones[0].from { return y + zones[0].to - zones[0].from }
        for i in 1..<zones.count where y <= zones[i].from {
            let a = zones[i - 1], b = zones[i]
            return a.to + (y - a.from) / (b.from - a.from) * (b.to - a.to)
        }
        let last = zones[zones.count - 1]
        return y + last.to - last.from
    }

    // MARK: - Curve flattening

    /// Walks a TrueType contour (on/off-curve points, implied midpoints) as
    /// straight segments, subdividing each quadratic to ~0.02px.
    static func flatten(_ contour: [TrueTypeFont.Point], _ emit: (SIMD2<Float>, SIMD2<Float>) -> Void) {
        guard contour.count > 1 else { return }
        func v(_ p: TrueTypeFont.Point) -> SIMD2<Float> { SIMD2(p.x, p.y) }
        // Start on an on-curve point; if none exists start at the midpoint of the first two.
        var points = contour
        if let firstOn = points.firstIndex(where: \.onCurve) {
            points = Array(points[firstOn...] + points[..<firstOn])
        } else {
            let mid = (v(points[0]) + v(points[1])) / 2
            points = [TrueTypeFont.Point(x: mid.x, y: mid.y, onCurve: true)] + Array(points[1...]) + [points[0]]
        }
        points.append(points[0])
        var current = v(points[0])
        var control: SIMD2<Float>?
        func quad(_ p0: SIMD2<Float>, _ c: SIMD2<Float>, _ p1: SIMD2<Float>) {
            let deviation = simd_length(p0 - 2 * c + p1) / 4
            let n = max(1, min(24, Int((deviation / 0.02).squareRoot().rounded(.up))))
            var last = p0
            for i in 1...n {
                let t = Float(i) / Float(n), u = 1 - t
                let p = u * u * p0 + 2 * u * t * c + t * t * p1
                emit(last, p); last = p
            }
        }
        for point in points.dropFirst() {
            let p = v(point)
            if point.onCurve {
                if let c = control { quad(current, c, p); control = nil } else { emit(current, p) }
                current = p
            } else if let c = control {
                let mid = (c + p) / 2
                quad(current, c, mid); current = mid; control = p
            } else {
                control = p
            }
        }
        if let c = control { quad(current, c, v(points[0])) }
    }
}

@inline(__always) private func simd_length(_ v: SIMD2<Float>) -> Float { (v.x * v.x + v.y * v.y).squareRoot() }
