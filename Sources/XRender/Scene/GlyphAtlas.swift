import Foundation

/// One glyph's placement in an atlas texture and its layout metrics, all in
/// atlas pixels at the atlas's `pixelSize`.
public struct GlyphBox: Sendable, Equatable {
    public var x, y, w, h: Float      // sub-rect in the atlas texture
    public var advance: Float         // pen advance
    public var left: Float            // bearing: baseline origin → glyph left
    public var top: Float             // bearing: baseline → glyph top
    public init(x: Float, y: Float, w: Float, h: Float, advance: Float, left: Float, top: Float) {
        self.x = x; self.y = y; self.w = w; self.h = h
        self.advance = advance; self.left = left; self.top = top
    }
}

/// A baked font: its atlas texture handle, dimensions and glyph table. Produced
/// by `Scripts/make-glyph-atlas.swift`, loaded by the presentation layer.
public struct FontAtlas: Sendable, Equatable {
    public var texture: TextureID
    public var atlasWidth: Float
    public var atlasHeight: Float
    public var pixelSize: Float
    public var ascent: Float
    public var descent: Float
    public var lineHeight: Float
    public var glyphs: [Character: GlyphBox]
    /// Cap height used to match the legacy vector font's 7-unit em.
    public var capHeight: Float
    /// Atlas-pixel reach of the signed distance stored in the red channel
    /// (encoded `128 + d / sdfRange * 127`). Per atlas: a native-size atlas
    /// needs only a few pixels, an 80px one needs ~24.
    public var sdfRange: Float
    /// `true` when the atlas was baked at the pixel size it is drawn at, so the
    /// compiler can place it 1:1 on whole framebuffer pixels instead of scaling.
    public var native: Bool

    public init(texture: TextureID, atlasWidth: Float, atlasHeight: Float, pixelSize: Float,
                ascent: Float, descent: Float, lineHeight: Float, glyphs: [Character: GlyphBox],
                capHeight: Float? = nil, sdfRange: Float = 24, native: Bool = false) {
        self.sdfRange = sdfRange
        self.native = native
        self.texture = texture
        self.atlasWidth = atlasWidth; self.atlasHeight = atlasHeight
        self.pixelSize = pixelSize
        self.ascent = ascent; self.descent = descent; self.lineHeight = lineHeight
        self.glyphs = glyphs
        self.capHeight = capHeight ?? glyphs["H"]?.top ?? glyphs["A"]?.top ?? pixelSize * 0.7
    }

    /// Logical scale so a cap-height glyph is `7 * textScale` tall — matching
    /// `TextMesher`'s em so atlas text drops into legacy call sites.
    public func drawScale(_ textScale: Float) -> Float { 7 * textScale / max(capHeight, 1) }

    /// Advance width of `string` in logical units at `textScale`.
    public func width(_ string: String, textScale: Float) -> Float {
        let s = drawScale(textScale)
        var w: Float = 0
        for ch in string { w += (glyphs[ch]?.advance ?? glyphs[" "]?.advance ?? pixelSize * 0.5) * s }
        return w
    }

    /// The real ink bounding box of `string`, baseline-relative, in atlas
    /// pixels (before `drawScale`) — the tallest ascender to the deepest
    /// descender among the glyphs actually present, not a nominal font-wide
    /// metric. `nil` if none of `string`'s characters have a packed glyph.
    /// Used for true vertical centering instead of a fixed cap-height guess,
    /// so it works the same for a numeral-only Latin string, full CJK text,
    /// or a mix — whatever the string's own glyphs actually occupy.
    public func verticalInkBounds(_ string: String) -> (top: Float, bottom: Float)? {
        var top: Float?
        var bottom: Float?
        for ch in string {
            guard let g = glyphs[ch], g.h > 0 else { continue }
            let glyphBottom = g.top - g.h
            top = max(top ?? g.top, g.top)
            bottom = min(bottom ?? glyphBottom, glyphBottom)
        }
        guard let t = top, let b = bottom else { return nil }
        return (t, b)
    }
}

public struct FontBook: Sendable, Equatable {
    /// One reference atlas per role (the largest, for legacy single-size users
    /// and the CPU exporter).
    public var atlases: [FontRole: FontAtlas]
    /// Every size baked for a role, ascending by `pixelSize`. Empty for a
    /// classic single-atlas book.
    public var sized: [FontRole: [FontAtlas]]
    public init(atlases: [FontRole: FontAtlas] = [:], sized: [FontRole: [FontAtlas]] = [:]) {
        self.atlases = atlases
        self.sized = sized
    }
    public subscript(_ role: FontRole) -> FontAtlas? { atlases[role] }

    /// The atlas sized closest to `capPixels` framebuffer pixels of cap height
    /// (see `closest`) — falling back to the role's reference atlas.
    public func atlas(for role: FontRole, capPixels: Float) -> FontAtlas? {
        guard let candidates = sized[role], !candidates.isEmpty, capPixels > 0 else { return atlases[role] }
        return Self.closest(candidates, capPixels: capPixels)
    }

    /// The candidate whose whole-pixel em size is nearest the size that would
    /// put a cap-height glyph at `capPixels`. This is the same rule
    /// `DynamicFontBook.prepare` uses to decide which size to bake, so drawing
    /// and preparation always agree — choosing by raw cap height instead
    /// disagrees near the midpoint between two sizes (e.g. 12px vs 16px) once
    /// both exist.
    private static func closest(_ candidates: [FontAtlas], capPixels: Float) -> FontAtlas? {
        guard let first = candidates.first else { return nil }
        let ratio = max(0.1, first.capHeight / max(first.pixelSize, 1))
        let desired = max(6, capPixels / ratio)
        return candidates.min { abs($0.pixelSize - desired) < abs($1.pixelSize - desired) }
    }

    /// The closest-size page that contains `character`. Dynamic font books may
    /// split one size across several texture pages, so callers that draw a
    /// string must select the page per glyph rather than assuming one texture
    /// contains the whole font.
    public func atlas(for role: FontRole, capPixels: Float, character: Character) -> FontAtlas? {
        let candidates = sized[role] ?? []
        let holding = candidates.filter { $0.glyphs[character] != nil }
        guard capPixels > 0, let best = Self.closest(holding, capPixels: capPixels) else {
            return atlas(for: role, capPixels: capPixels)
        }
        return best
    }
}
