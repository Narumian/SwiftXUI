import Testing
@testable import XRender

/// A square glyph whose edge sits at a known sub-pixel position, rasterised at
/// any `supersample`: the ink spans x in [1, 3.5) px, y in [0, 3) px.
private final class SquareGlyphs: GlyphRasterizer {
    let metrics = FontMetrics(ascent: 7, descent: 2, lineHeight: 10, capHeight: 7)
    private func bitmap(k: Int) -> RasterizedGlyph {
        let w = 4 * k, h = 3 * k
        var c = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            // exact coverage of the pixel cell (x/k ... (x+1)/k) against the ink x-range [1, 3.5)
            let x0 = Float(x) / Float(k), x1 = Float(x + 1) / Float(k)
            let overlap = max(0, min(x1, 3.5) - max(x0, 1)) / (x1 - x0)
            c[y * w + x] = UInt8(overlap * 255 + 0.5)
        } }
        return RasterizedGlyph(coverage: c, width: w, height: h, advance: 5, left: 0, top: 3)
    }
    func rasterize(_ ch: Character) -> RasterizedGlyph? { bitmap(k: 1) }
    func rasterize(_ ch: Character, supersample: Int) -> RasterizedGlyph? { bitmap(k: supersample) }
}

@Test func supersampledDistanceFieldLocatesTheEdgeBelowOnePixel() {
    let atlas = DynamicFontAtlas(texture: TextureID(9), rasterizer: SquareGlyphs(), pixelSize: 10,
                                 width: 128, height: 128, spread: 4, supersample: 4, native: true)
    #expect(atlas.ensure("A"))
    let g = atlas.snapshot().glyphs["A"]!
    // sample the SDF along the glyph's middle row; encoded 128 + d/4*127
    let row = Int(g.y) + Int(g.h) / 2
    func d(atX x: Float) -> Float {
        let v = Float(atlas.sdfPixels[row * atlas.width + Int(g.x) + Int(x)])
        return (v - 128) / 127 * 4
    }
    // Ink runs [1, 3.5) in glyph space, gutter = spread = 4 → pixel centres at gutter + x + 0.5.
    // Right edge at 3.5: the pixel centred at 3.5 is on the contour; its neighbours are ±1 px away.
    #expect(abs(d(atX: 4 + 3)) < 0.2)                       // centre 3.5 → on the edge
    #expect(abs(d(atX: 4 + 2) - 1.0) < 0.2)                 // centre 2.5 → 1.0 inside
    #expect(abs(d(atX: 4 + 4) + 1.0) < 0.2)                 // centre 4.5 → 1.0 outside
}

@Test func fontBookPicksTheAtlasClosestToTheRequestedCapHeight() {
    func atlas(_ id: UInt32, size: Float) -> FontAtlas {
        FontAtlas(texture: TextureID(id), atlasWidth: 64, atlasHeight: 64, pixelSize: size,
                  ascent: size, descent: 0, lineHeight: size, glyphs: [:], capHeight: size * 0.7,
                  sdfRange: 4, native: true)
    }
    let book = FontBook(atlases: [.ui: atlas(3, size: 40)],
                        sized: [.ui: [atlas(1, size: 12), atlas(2, size: 20), atlas(3, size: 40)]])
    #expect(book.atlas(for: .ui, capPixels: 8.4)?.texture == TextureID(1))     // 12 * 0.7
    #expect(book.atlas(for: .ui, capPixels: 13)?.texture == TextureID(2))
    #expect(book.atlas(for: .ui, capPixels: 100)?.texture == TextureID(3))
    #expect(book.atlas(for: .display, capPixels: 10) == nil)
}

@Test func nativeAtlasTextLandsOnWholeFramebufferPixels() {
    let glyph = GlyphBox(x: 0, y: 0, w: 8, h: 8, advance: 7.3, left: 0.4, top: 8)
    let atlas = FontAtlas(texture: TextureID(5), atlasWidth: 64, atlasHeight: 64, pixelSize: 12,
                          ascent: 10, descent: 2, lineHeight: 12, glyphs: ["A": glyph, "B": glyph],
                          capHeight: 8, sdfRange: 4, native: true)
    var scene = Scene()
    // capPixels = 7 * 1.2 * 1 = 8.4 → within 35% of the atlas's 8px cap → native placement
    scene.append(.text(TextCommand(string: "AB", origin: RenderPoint(x: 10.37, y: 20.61), scale: 1.2,
                                   color: .white, font: .ui)))
    let frame = SceneCompiler.compile(scene, canvas: RenderSize(width: 200, height: 100),
                                      framebuffer: RenderSize(width: 200, height: 100),
                                      fonts: FontBook(atlases: [.ui: atlas], sized: [.ui: [atlas]]))
    #expect(frame.fontVertices.count == 2 * 6 * 14)
    // every vertex carries the atlas's sdf range as its 14th float
    #expect(stride(from: 13, to: frame.fontVertices.count, by: 14).allSatisfy { frame.fontVertices[$0] == 4 })
    // NDC -> framebuffer pixels: x = (ndc + 1) / 2 * 200, y = (1 - ndc) / 2 * 100
    for v in stride(from: 0, to: frame.fontVertices.count, by: 14) {
        let x = (frame.fontVertices[v] + 1) / 2 * 200, y = (1 - frame.fontVertices[v + 1]) / 2 * 100
        #expect(abs(x - x.rounded()) < 1e-3, "x \(x)")
        #expect(abs(y - y.rounded()) < 1e-3, "y \(y)")
    }
}

@Test func aBakedPageRestoresWithTheSameGlyphsAndPixels() {
    let baked = DynamicFontAtlas(texture: TextureID(9), rasterizer: SquareGlyphs(), pixelSize: 10,
                                 width: 128, height: 128, spread: 4, supersample: 4, native: true)
    #expect(baked.ensure("AB"))
    let restored = DynamicFontAtlas(restoring: baked.snapshot(), sdf: baked.sdfPixels,
                                    spread: baked.spread, supersample: baked.supersample)
    #expect(restored.snapshot().glyphs == baked.snapshot().glyphs)
    #expect(restored.isFull)                                // new characters go to a fresh page
    #expect(restored.contains("A") && !restored.contains("Z"))
    let a = baked.rgba(), b = restored.rgba()
    #expect(a.count == b.count)
    // The distance channel is identical; coverage is read back off it, so it
    // may differ by rounding but never by more than a few levels.
    var worst = 0
    for i in stride(from: 0, to: a.count, by: 4) {
        #expect(a[i] == b[i])
        worst = max(worst, abs(Int(a[i + 3]) - Int(b[i + 3])))
    }
    #expect(worst <= 40)
}

@Test func drawingPicksTheSameSizePreparationBaked() {
    // Two sizes of one role whose cap heights straddle a 9.8px request: the size
    // chosen by em (what `prepare` bakes for) must win, not the nearer cap height.
    func atlas(_ size: Float, cap: Float) -> FontAtlas {
        FontAtlas(texture: TextureID(UInt32(size)), atlasWidth: 64, atlasHeight: 64, pixelSize: size,
                  ascent: size, descent: 0, lineHeight: size, glyphs: ["x": GlyphBox(x: 0, y: 0, w: 1, h: 1, advance: 1, left: 0, top: 1)],
                  capHeight: cap)
    }
    let book = FontBook(sized: [.numeric: [atlas(12, cap: 8.4), atlas(16, cap: 11.2)]])
    // desired em = 9.8 / 0.7 = 14 → 16 is nearer only when ties break upward; use 14.4 (cap 10.08).
    #expect(book.atlas(for: .numeric, capPixels: 10.08, character: "x")?.pixelSize == 16)
    #expect(book.atlas(for: .numeric, capPixels: 9.4, character: "x")?.pixelSize == 12)
}

/// A glyph present only on a smaller page must still be drawn at the requested size: the
/// scale belongs to the page each glyph comes from, not to the page the string was matched to.
@Test func aGlyphTakenFromASmallerPageIsScaledToTheRequestedSize() {
    func page(_ id: UInt32, size: Float, glyphs: [Character: GlyphBox]) -> FontAtlas {
        FontAtlas(texture: TextureID(id), atlasWidth: 256, atlasHeight: 256, pixelSize: size,
                  ascent: size, descent: 0, lineHeight: size, glyphs: glyphs, capHeight: size * 0.7,
                  sdfRange: 4, native: true)
    }
    // "A" exists on both pages, "B" only on the 20px page; both are as tall as their page's cap.
    let big = page(2, size: 40, glyphs: ["A": GlyphBox(x: 0, y: 0, w: 28, h: 28, advance: 30, left: 0, top: 28)])
    let small = page(1, size: 20, glyphs: [
        "A": GlyphBox(x: 0, y: 0, w: 14, h: 14, advance: 15, left: 0, top: 14),
        "B": GlyphBox(x: 20, y: 0, w: 14, h: 14, advance: 15, left: 0, top: 14),
    ])
    var scene = Scene()
    // capPixels = 7 * 4 = 28 → the 40px page (cap 28) is the match.
    scene.append(.text(TextCommand(string: "AB", origin: RenderPoint(x: 0, y: 0), scale: 4,
                                   color: .white, font: .ui)))
    let frame = SceneCompiler.compile(scene, canvas: RenderSize(width: 400, height: 200),
                                      framebuffer: RenderSize(width: 400, height: 200),
                                      fonts: FontBook(atlases: [.ui: big], sized: [.ui: [small, big]]))
    // Two glyphs, six vertices each, 14 floats per vertex. Measure each quad's pixel height from NDC y.
    func quadHeight(_ glyph: Int) -> Float {
        let ys = (0..<6).map { frame.fontVertices[(glyph * 6 + $0) * 14 + 1] }
        return (ys.max()! - ys.min()!) / 2 * 200
    }
    #expect(frame.fontVertices.count == 2 * 6 * 14)
    #expect(abs(quadHeight(0) - quadHeight(1)) < 0.5, "A \(quadHeight(0)) vs B \(quadHeight(1))")
}
