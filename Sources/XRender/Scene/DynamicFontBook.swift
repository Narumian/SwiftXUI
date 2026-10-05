import Foundation

/// Lazily builds renderer-neutral font pages from bundled TrueType faces.
///
/// A book is intentionally small and stateful: callers prepare the current
/// scene, snapshot it for `SceneCompiler`, then sync only newly-created or
/// dirtied pages to their renderer. The owner should keep it on its render
/// actor; the unchecked sendability only lets a prepared result cross an
/// async boundary when the caller chooses to do so.
public final class DynamicFontBook: @unchecked Sendable {
    public struct SizeKey: Hashable, Sendable {
        public var role: FontRole
        public var pixelSize: Int

        public init(role: FontRole, pixelSize: Int) {
            self.role = role
            self.pixelSize = pixelSize
        }
    }

    private let fonts: [FontRole: TrueTypeFont]
    private var pages: [SizeKey: [DynamicFontAtlas]] = [:]
    private var missing: [SizeKey: Set<Character>] = [:]
    private var registered: Set<TextureID> = []
    private var nextTexture: UInt32

    public var maxPagesPerSize = 16

    /// Discrete sizes prevent responsive layout from creating a new page for
    /// every intermediate scale.
    public var pixelSizes = [8, 10, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 128, 160, 192]

    public init(fonts: [FontRole: TrueTypeFont], textureBase: UInt32 = 100_000) {
        self.fonts = fonts
        self.nextTexture = textureBase
    }

    /// Adds only the glyphs used by `scene`, at the nearest discrete size.
    public func prepare(_ scene: Scene, pixelScale: Float = 1) {
        func prepare(_ commands: [DrawCommand]) {
            for command in commands {
                switch command {
                case .text(let text):
                    guard let font = fonts[text.font] else { continue }
                    let size = pixelSize(for: font, capPixels: 7 * text.scale * pixelScale)
                    ensure(text.string, role: text.font, pixelSize: size)
                case .shaderLayer(let layer):
                    prepare(layer.commands)
                case .x3d(let x3d):
                    prepare(x3d.graph.viewCommands)
                case .shape, .sprite, .material:
                    break
                }
            }
        }

        prepare(scene.commands)
    }

    /// Ensures a string in a stable reference-size page, useful for tools that
    /// do not have a full scene yet.
    public func prepare<S: StringProtocol>(_ string: S, role: FontRole, pixelSize: Int = 32) {
        ensure(string, role: role, pixelSize: pixelSize)
    }

    /// Returns the value snapshot consumed by `SceneCompiler`.
    public func snapshot() -> FontBook {
        var sized: [FontRole: [FontAtlas]] = [:]
        for (key, atlases) in pages {
            sized[key.role, default: []].append(contentsOf: atlases.map { $0.snapshot() })
        }

        var reference: [FontRole: FontAtlas] = [:]
        for (role, atlases) in sized {
            let ordered = atlases.sorted { $0.pixelSize < $1.pixelSize }
            sized[role] = ordered
            reference[role] = ordered.last
        }
        return FontBook(atlases: reference, sized: sized)
    }

    /// Registers new pages and updates only dirty rows on pages already sent
    /// to the renderer. The closures keep XRender independent of WGPU/Metal.
    public func sync(
        register: (_ texture: TextureID, _ rgba: [UInt8], _ width: Int, _ height: Int) -> Void,
        update: (_ texture: TextureID, _ rgba: [UInt8], _ y: Int, _ width: Int, _ height: Int) -> Void
    ) {
        for atlases in pages.values {
            for atlas in atlases {
                if registered.contains(atlas.texture) {
                    guard let rows = atlas.dirtyRows else { continue }
                    update(atlas.texture, atlas.rgba(rows: rows), rows.lowerBound, atlas.width, rows.count)
                } else {
                    register(atlas.texture, atlas.rgba(), atlas.width, atlas.height)
                    registered.insert(atlas.texture)
                }
                atlas.clearDirty()
            }
        }
    }

    private func pixelSize(for font: TrueTypeFont, capPixels: Float) -> Int {
        let ratio = max(0.1, Float(font.capHeight) / Float(font.unitsPerEm))
        let desired = max(6, capPixels / ratio)
        return pixelSizes.min {
            abs(Float($0) - desired) < abs(Float($1) - desired)
        } ?? 32
    }

    private func makePage(for key: SizeKey, font: TrueTypeFont) -> DynamicFontAtlas {
        let layout = Self.layout(pixelSize: key.pixelSize)
        let page = DynamicFontAtlas(
            texture: TextureID(nextTexture),
            rasterizer: TrueTypeGlyphSource(font: font, pixelSize: Float(key.pixelSize)),
            pixelSize: Float(key.pixelSize),
            width: layout.dimension,
            height: layout.dimension,
            spread: layout.spread,
            supersample: layout.supersample,
            native: true
        )
        nextTexture += 1
        pages[key, default: []].append(page)
        return page
    }

    private func ensure<S: StringProtocol>(_ string: S, role: FontRole, pixelSize: Int) {
        guard let font = fonts[role] else { return }
        let key = SizeKey(role: role, pixelSize: pixelSize)
        if pages[key] == nil { _ = makePage(for: key, font: font) }

        for character in string {
            if missing[key, default: []].contains(character) { continue }
            if pages[key]?.contains(where: { $0.contains(character) }) == true { continue }

            var settled = false
            for page in pages[key] ?? [] where !page.isFull {
                page.ensure(String(character))
                if page.contains(character) {
                    settled = true
                    break
                }
                if page.lacks(character) {
                    missing[key, default: []].insert(character)
                    settled = true
                    break
                }
            }
            if settled { continue }

            guard (pages[key]?.count ?? 0) < maxPagesPerSize else {
                missing[key, default: []].insert(character)
                continue
            }
            let page = makePage(for: key, font: font)
            page.ensure(String(character))
            if !page.contains(character) { missing[key, default: []].insert(character) }
        }
    }

    private static func layout(pixelSize: Int) -> (spread: Int, dimension: Int, supersample: Int) {
        let spread = min(24, Int((Float(pixelSize) * 0.2).rounded(.up)) + 2)
        let dimension = pixelSize <= 40 ? 256 : (pixelSize <= 80 ? 512 : 1024)
        let supersample = pixelSize <= 32 ? 4 : (pixelSize <= 64 ? 2 : 1)
        return (spread, dimension, supersample)
    }
}
