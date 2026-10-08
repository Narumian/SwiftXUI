import Foundation

/// One rasterised glyph, top-down (row 0 is the glyph's visual top), single
/// channel = coverage. `advance` / `left` / `top` are in atlas pixels at the
/// rasteriser's `pixelSize`, matching `GlyphBox`.
public struct RasterizedGlyph: Sendable {
    public var coverage: [UInt8]
    public var width: Int
    public var height: Int
    public var advance: Float
    public var left: Float
    public var top: Float
    public init(coverage: [UInt8], width: Int, height: Int, advance: Float, left: Float, top: Float) {
        self.coverage = coverage; self.width = width; self.height = height
        self.advance = advance; self.left = left; self.top = top
    }
}

public struct FontMetrics: Sendable {
    public var ascent: Float
    public var descent: Float
    public var lineHeight: Float
    public var capHeight: Float
    public init(ascent: Float, descent: Float, lineHeight: Float, capHeight: Float) {
        self.ascent = ascent; self.descent = descent; self.lineHeight = lineHeight; self.capHeight = capHeight
    }
}

/// Turns characters into coverage bitmaps. The platform-specific part of the
/// text pipeline (CoreText on Apple; DirectWrite / FreeType elsewhere). Used on
/// the render thread only — not `Sendable`.
public protocol GlyphRasterizer: AnyObject {
    var metrics: FontMetrics { get }
    /// `nil` when the font has no glyph for `ch` (caller stops retrying it).
    func rasterize(_ ch: Character) -> RasterizedGlyph?
    /// The same glyph in the same frame, rasterised `supersample`× finer:
    /// `width`/`height` are exactly `supersample`× those of `rasterize(_:)`.
    /// Lets the atlas measure a sub-pixel-accurate distance field. `nil` when
    /// the rasteriser cannot do this (the atlas falls back to the 1× bitmap).
    func rasterize(_ ch: Character, supersample: Int) -> RasterizedGlyph?
}

public extension GlyphRasterizer {
    func rasterize(_ ch: Character, supersample: Int) -> RasterizedGlyph? { nil }
}

/// Stands in for the font on a page restored from a bake: it never rasterises.
private final class BakedRasterizer: GlyphRasterizer {
    let metrics: FontMetrics
    init(metrics: FontMetrics) { self.metrics = metrics }
    func rasterize(_ ch: Character) -> RasterizedGlyph? { nil }
}

/// A glyph atlas filled on demand: the first time a character is drawn it is
/// rasterised, shelf-packed into a CPU bitmap, and its row range marked dirty
/// for the renderer to upload. No pre-baked charset, no build step.
public final class DynamicFontAtlas {
    /// Atlas-pixel reach of the signed-distance field. It also becomes the
    /// transparent gutter around each glyph, so an outline never samples its
    /// neighbouring glyph in the packed texture.
    public static let sdfRange = 24
    public let texture: TextureID
    public let pixelSize: Float
    public let width: Int
    public let height: Int
    /// Single-channel coverage, `width * height`, top-down.
    public private(set) var pixels: [UInt8]
    /// Signed distance encoded around 128 (inside > 128, outside < 128).
    /// Kept separate from coverage: the CPU exporter continues to use the
    /// latter as an ordinary alpha mask.
    public private(set) var sdfPixels: [UInt8]
    /// Inclusive-exclusive row range written since `clearDirty()`; nil if clean.
    public private(set) var dirtyRows: Range<Int>?

    private let rasterizer: GlyphRasterizer
    private let metrics: FontMetrics
    private var boxes: [Character: GlyphBox] = [:]
    private var absent: Set<Character> = []
    private var version = 0            // bumps when `boxes` changes → snapshot cache invalidates
    private var cachedSnapshot: (version: Int, atlas: FontAtlas)?

    // shelf packer
    private let pad = 1
    private var penX: Int
    private var penY: Int
    private var shelfHeight = 0
    private var full = false

    /// Atlas-pixel reach of this atlas's distance field (also the transparent
    /// gutter around each glyph).
    public let spread: Int
    /// `> 1`: measure the distance field on a `supersample`× finer outline.
    public let supersample: Int
    /// Baked at the pixel size it is drawn at (see `FontAtlas.native`).
    public let native: Bool
    /// No further glyph can be packed into this page. Used by the page
    /// allocator to avoid rasterising against already-full pages.
    public var isFull: Bool { full }

    public init(texture: TextureID, rasterizer: GlyphRasterizer, pixelSize: Float,
                width: Int = 2048, height: Int = 2048,
                spread: Int = DynamicFontAtlas.sdfRange, supersample: Int = 1, native: Bool = false) {
        self.spread = spread
        self.supersample = max(1, supersample)
        self.native = native
        self.texture = texture
        self.rasterizer = rasterizer
        self.metrics = rasterizer.metrics
        self.pixelSize = pixelSize
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 0, count: width * height)
        self.sdfPixels = [UInt8](repeating: 0, count: width * height)
        self.penX = pad
        self.penY = pad
    }

    /// Rebuilds a page that was baked ahead of time: `atlas` is its glyph table
    /// (`snapshot()` of the baked page) and `sdf` its distance field, `width *
    /// height` bytes, top-down. The page is closed to new glyphs (`isFull`), so
    /// characters it lacks go to a fresh page instead. Coverage is not kept: the
    /// CPU exporter gets it from the distance field inside `rgba`.
    public init(restoring atlas: FontAtlas, sdf: [UInt8], spread: Int, supersample: Int) {
        let width = Int(atlas.atlasWidth), height = Int(atlas.atlasHeight)
        precondition(sdf.count == width * height, "baked distance field does not match the page size")
        self.spread = spread
        self.supersample = max(1, supersample)
        self.native = atlas.native
        self.texture = atlas.texture
        self.rasterizer = BakedRasterizer(metrics: FontMetrics(
            ascent: atlas.ascent, descent: atlas.descent,
            lineHeight: atlas.lineHeight, capHeight: atlas.capHeight))
        self.metrics = rasterizer.metrics
        self.pixelSize = atlas.pixelSize
        self.width = width
        self.height = height
        self.sdfPixels = sdf
        // Coverage is derived from the distance field when `rgba` is built.
        self.pixels = []
        self.penX = pad
        self.penY = pad
        self.boxes = atlas.glyphs
        self.full = true
        self.version = 1
    }

    /// Whether the font has no glyph for `ch` (it was tried and skipped).
    public func lacks(_ ch: Character) -> Bool { absent.contains(ch) }

    /// Rasterise + pack any character in `string` not seen yet. Returns false if
    /// the atlas ran out of room (glyphs already packed still render).
    @discardableResult
    public func ensure<S: StringProtocol>(_ string: S) -> Bool {
        var ok = true
        for ch in string where boxes[ch] == nil && !absent.contains(ch) {
            if !pack(ch) { ok = false }
        }
        return ok
    }

    public func clearDirty() { dirtyRows = nil }

    /// Characters packed on this page so far.
    public var glyphCount: Int { boxes.count }

    /// Whether this page already contains a rasterised entry for `ch`.
    /// Pages are filled incrementally by `DynamicFontBook`; exposing this tiny
    /// query lets the book route a glyph to another page when the current one
    /// is full without re-rasterising it.
    public func contains(_ ch: Character) -> Bool { boxes[ch] != nil }

    /// A value snapshot for `SceneCompiler` / exporters. Cheap while no new
    /// glyph was packed (COW dictionary + version guard).
    public func snapshot() -> FontAtlas {
        if let cached = cachedSnapshot, cached.version == version { return cached.atlas }
        let atlas = FontAtlas(
            texture: texture, atlasWidth: Float(width), atlasHeight: Float(height),
            pixelSize: pixelSize, ascent: metrics.ascent, descent: metrics.descent,
            lineHeight: metrics.lineHeight, glyphs: boxes, capHeight: metrics.capHeight,
            sdfRange: Float(spread), native: native
        )
        cachedSnapshot = (version, atlas)
        return atlas
    }

    /// RGBA8 for the whole atlas. Red holds the signed distance for the GPU
    /// font pipeline; alpha (and GB) retain ordinary coverage for the CPU
    /// exporter and tooling.
    public func rgba() -> [UInt8] {
        rgba(rows: 0..<height)
    }

    /// RGBA8 for just `rows` (full-width bands stay 256-byte-row aligned).
    public func rgba(rows: Range<Int>) -> [UInt8] {
        let clamped = max(0, rows.lowerBound)..<min(height, rows.upperBound)
        guard clamped.lowerBound < clamped.upperBound else { return [] }
        return Self.expand(sdf: sdfPixels, coverage: pixels, width: width,
                           rows: clamped, spread: Float(spread))
    }

    /// Optimised even in debug builds: a page is millions of pixels and this
    /// runs for every page at launch. `coverage` empty = a restored page, whose
    /// coverage is read back off the distance field.
    @_optimize(speed)
    private static func expand(sdf: [UInt8], coverage: [UInt8], width: Int,
                               rows: Range<Int>, spread: Float) -> [UInt8] {
        let count = width * rows.count
        var lookup = [UInt8](repeating: 0, count: 256)   // distance byte → coverage
        for value in 0..<256 {
            // Inverse of the encoding in `signedDistance`: 128 + d / range * 127.
            let distance = (Float(value) - 128) / 127 * spread
            lookup[value] = UInt8(max(0, min(255, (0.5 + distance) * 255)))
        }
        let restored = coverage.isEmpty
        return [UInt8](unsafeUninitializedCapacity: count * 4) { out, initialized in
            sdf.withUnsafeBufferPointer { d in
                coverage.withUnsafeBufferPointer { c in
                    lookup.withUnsafeBufferPointer { lut in
                        expandPixels(d.baseAddress!, restored ? nil : c.baseAddress!, lut.baseAddress!,
                                     start: rows.lowerBound * width, count: count, into: out.baseAddress!)
                    }
                }
            }
            initialized = count * 4
        }
    }

    /// The pixel loop, on its own so `@_optimize(speed)` applies to it (it does
    /// not reach the body of a closure).
    @_optimize(speed)
    private static func expandPixels(
        _ d: UnsafePointer<UInt8>, _ c: UnsafePointer<UInt8>?, _ lut: UnsafePointer<UInt8>,
        start: Int, count: Int, into out: UnsafeMutablePointer<UInt8>
    ) {
        var o = 0
        var i = start
        let end = start + count
        while i < end {
            let distance = d[i]
            let a = c.map { $0[i] } ?? lut[Int(distance)]
            out[o] = distance; out[o + 1] = a; out[o + 2] = a; out[o + 3] = a
            o += 4; i += 1
        }
    }

    // MARK: packing

    private func pack(_ ch: Character) -> Bool {
        // Check before rasterisation: once a page is full, trying every later
        // glyph here would repeat the expensive font rasteriser needlessly.
        if full { return false }
        guard let glyph = rasterizer.rasterize(ch) else { absent.insert(ch); return true }

        if glyph.width <= 0 || glyph.height <= 0 {          // space / zero-area: metrics only
            boxes[ch] = GlyphBox(x: 0, y: 0, w: 0, h: 0, advance: glyph.advance, left: glyph.left, top: glyph.top)
            version += 1
            return true
        }
        // The SDF field needs transparent pixels around the real glyph so an
        // outline has room to grow without bleeding from an adjacent glyph.
        let gutter = spread
        let packedWidth = glyph.width + gutter * 2
        let packedHeight = glyph.height + gutter * 2
        if penX + packedWidth + pad > width {                // next shelf
            penX = pad
            penY += shelfHeight + pad
            shelfHeight = 0
        }
        guard penY + packedHeight + pad <= height else { full = true; return false }

        var coverage = [UInt8](repeating: 0, count: packedWidth * packedHeight)
        for row in 0..<glyph.height {
            let dst = (row + gutter) * packedWidth + gutter
            let src = row * glyph.width
            coverage.replaceSubrange(dst..<(dst + glyph.width), with: glyph.coverage[src..<(src + glyph.width)])
        }
        let distances: [UInt8]
        if supersample > 1, let fine = rasterizer.rasterize(ch, supersample: supersample),
           fine.width == glyph.width * supersample, fine.height == glyph.height * supersample {
            distances = signedDistance(fine: fine.coverage, fineWidth: fine.width, fineHeight: fine.height,
                                       gutter: gutter, width: packedWidth, height: packedHeight)
        } else {
            distances = signedDistance(coverage, width: packedWidth, height: packedHeight)
        }

        for row in 0..<packedHeight {
            let dst = (penY + row) * width + penX
            let src = row * packedWidth
            for col in 0..<packedWidth {
                pixels[dst + col] = coverage[src + col]
                sdfPixels[dst + col] = distances[src + col]
            }
        }
        boxes[ch] = GlyphBox(x: Float(penX), y: Float(penY), w: Float(packedWidth), h: Float(packedHeight),
                             advance: glyph.advance, left: glyph.left - Float(gutter), top: glyph.top + Float(gutter))
        markDirty(rows: penY..<(penY + packedHeight))
        version += 1

        shelfHeight = max(shelfHeight, packedHeight)
        penX += packedWidth + pad
        return true
    }

    private func markDirty(rows: Range<Int>) {
        if let current = dirtyRows {
            dirtyRows = min(current.lowerBound, rows.lowerBound)..<max(current.upperBound, rows.upperBound)
        } else {
            dirtyRows = rows
        }
    }

    /// Exact squared Euclidean distance transform. It is computed once per
    /// newly seen glyph (never per frame), so contours stay round instead of
    /// inheriting the diamond-shaped steps of a cheap chamfer transform.
    private func signedDistance(_ coverage: [UInt8], width: Int, height: Int) -> [UInt8] {
        let count = width * height
        let inside = coverage.map { $0 >= 128 }
        let toInside = euclideanDistanceTransform(target: inside, width: width, height: height)
        let toOutside = euclideanDistanceTransform(target: inside.map { !$0 }, width: width, height: height)
        let range = Float(spread)
        return (0..<count).map { index in
            let distance = sqrt(inside[index] ? toOutside[index] : toInside[index])
            let signed = inside[index] ? distance : -distance
            let scaled = (signed / max(range, 1) * 127).rounded()
            // Empty / degenerate glyphs can yield ±inf or huge finite distances.
            guard scaled.isFinite else { return inside[index] ? UInt8(255) : 0 }
            let encoded = 128 + Int(min(127, max(-128, scaled)))
            return UInt8(min(255, max(0, encoded)))
        }
    }

    /// Sub-pixel-accurate distance field: the glyph outline was rasterised
    /// `supersample`× finer, so the 50% contour is located to 1/(2·supersample)
    /// px instead of a whole pixel. Distances are measured on the fine grid, then
    /// averaged over each `supersample`² block and expressed in atlas pixels.
    private func signedDistance(fine: [UInt8], fineWidth: Int, fineHeight: Int, gutter: Int,
                                width: Int, height: Int) -> [UInt8] {
        let k = supersample
        let fw = width * k, fh = height * k
        var inside = [Bool](repeating: false, count: fw * fh)
        for y in 0..<fineHeight {
            for x in 0..<fineWidth {
                inside[(y + gutter * k) * fw + x + gutter * k] = fine[y * fineWidth + x] >= 128
            }
        }
        let toInside = euclideanDistanceTransform(target: inside, width: fw, height: fh)
        let toOutside = euclideanDistanceTransform(target: inside.map { !$0 }, width: fw, height: fh)
        let range = Float(spread)
        var out = [UInt8](repeating: 0, count: width * height)
        let weight = 1 / Float(k * k * k)                      // mean over the block, fine px → atlas px
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                for by in 0..<k {
                    for bx in 0..<k {
                        let i = (y * k + by) * fw + x * k + bx
                        let d = sqrt(inside[i] ? toOutside[i] : toInside[i])
                        sum += inside[i] ? d : -d
                    }
                }
                let scaled = (sum * weight / max(range, 1) * 127).rounded()
                let encoded: Int
                if scaled.isFinite {
                    encoded = 128 + Int(min(127, max(-128, scaled)))
                } else {
                    encoded = inside[y * k * fw + x * k] ? 255 : 0
                }
                out[y * width + x] = UInt8(min(255, max(0, encoded)))
            }
        }
        return out
    }

    private func euclideanDistanceTransform(target: [Bool], width: Int, height: Int) -> [Float] {
        let infinity = Float.greatestFiniteMagnitude / 16
        var intermediate = [Float](repeating: 0, count: width * height)
        for x in 0..<width {
            let column = (0..<height).map { target[$0 * width + x] ? 0 : infinity }
            let transformed = transform1D(column)
            for y in 0..<height { intermediate[y * width + x] = transformed[y] }
        }
        var output = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let transformed = transform1D(Array(intermediate[(y * width)..<(y * width + width)]))
            output.replaceSubrange((y * width)..<(y * width + width), with: transformed)
        }
        return output
    }

    /// Felzenszwalb/Huttenlocher's linear-time 1D lower-envelope transform.
    private func transform1D(_ source: [Float]) -> [Float] {
        let count = source.count
        guard count > 1 else { return source }
        let infinity = Float.greatestFiniteMagnitude / 32
        guard let first = source.indices.first(where: { source[$0] < infinity }) else {
            return [Float](repeating: infinity, count: count)
        }
        var sites = [Int](repeating: 0, count: count)
        var boundaries = [Float](repeating: 0, count: count + 1)
        var output = [Float](repeating: 0, count: count)
        var k = 0
        sites[0] = first
        boundaries[0] = -.infinity
        boundaries[1] = .infinity
        for q in (first + 1)..<count where source[q] < infinity {
            func cross(_ p: Int) -> Float {
                ((source[q] + Float(q * q)) - (source[p] + Float(p * p))) / Float(2 * (q - p))
            }
            // Recompute against the new top site after every pop: the old
            // `repeat` compared a stale intersection and wrote a wrong
            // boundary whenever a pop happened (≈half of the second-pass rows).
            var intersection = cross(sites[k])
            while intersection <= boundaries[k] {
                k -= 1
                intersection = cross(sites[k])
            }
            k += 1
            sites[k] = q
            boundaries[k] = intersection
            boundaries[k + 1] = .infinity
        }
        k = 0
        for q in 0..<count {
            while boundaries[k + 1] < Float(q) { k += 1 }
            let p = sites[k]
            let delta = Float(q - p)
            output[q] = delta * delta + source[p]
        }
        return output
    }
}
