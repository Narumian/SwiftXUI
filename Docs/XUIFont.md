# XApp fonts

An app supplies TrueType font data per `FontRole` through
`XAppConfiguration.fonts`. `fallbackFonts` optionally supplies ordered faces
for characters absent from the primary face. Font assets belong to the app;
XUIHost does not prescribe a typeface. With no configured faces, XUI uses the
existing vector fallback.

`XAppSession.render` prepares the glyphs needed for the scene and repeats
layout using their metrics. It records texture uploads retrievable through
`takeFontTextureUpdates()`. Hosts apply these to their renderer before drawing
the associated compiled frame. `XAppDriver` does this automatically for
`XTextureRenderer`; if the renderer does not expose texture support it uses the
vector fallback. `pixelScale` selects appropriate font atlas sizes for a display.

The current TrueType rasterizer handles single-scalar glyphs; shaping complex
scripts, combining sequences, color emoji, and bidirectional text is not yet
implemented. Fallback faces can supply individual missing glyphs but do not
provide text shaping. Font atlases are created lazily; first use of a large
character set may take longer than subsequent frames.
