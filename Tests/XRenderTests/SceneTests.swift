import Testing
import XShader
@testable import XRender

// MARK: - Transform2D

@Test func transformComposesLikeCoreGraphics() {
    let t = Transform2D.identity
        .translatedBy(x: 10, y: 20)
        .scaledBy(x: 2, y: 2)
    // scale first (local), then translate: (1,1) -> (2,2) -> (12,22)
    let p = t.apply(RenderPoint(x: 1, y: 1))
    #expect(abs(p.x - 12) < 1e-4)
    #expect(abs(p.y - 22) < 1e-4)
}

@Test func rotationQuarterTurn() {
    let p = Transform2D.rotation(.pi / 2).apply(RenderPoint(x: 1, y: 0))
    #expect(abs(p.x) < 1e-4)
    #expect(abs(p.y - 1) < 1e-4)
}

// MARK: - ShapeMesher

@Test func triangleMeshPassesThroughWithTransform() {
    let cmd = ShapeCommand(
        geometry: .triangles([0, 0, 1, 0, 0, 1]),
        color: .white,
        transform: .translation(x: 5, y: 5)
    )
    let m = ShapeMesher.mesh(cmd)
    #expect(m.count == 18)              // 3 verts * 6 floats
    #expect(m[0] == 5 && m[1] == 5)     // (0,0) -> (5,5)
}

@Test func polygonTriangulatesToNMinusTwoTriangles() {
    let square = [
        RenderPoint(x: 0, y: 0), RenderPoint(x: 10, y: 0),
        RenderPoint(x: 10, y: 10), RenderPoint(x: 0, y: 10),
    ]
    let m = ShapeMesher.mesh(ShapeCommand(geometry: .polygon(points: square), color: .white))
    #expect(m.count == 2 * 3 * 6)
}

@Test func concavePolygonTriangulates() {
    // Arrow / chevron — has one reflex vertex.
    let chevron = [
        RenderPoint(x: 0, y: 0), RenderPoint(x: 10, y: 5), RenderPoint(x: 0, y: 10),
        RenderPoint(x: 4, y: 5),
    ]
    let m = ShapeMesher.mesh(ShapeCommand(geometry: .polygon(points: chevron), color: .white))
    #expect(m.count == 2 * 3 * 6)       // 4 verts -> 2 triangles
}

@Test func meshingIsDeterministic() {
    let cmd = ShapeCommand(geometry: .circle(center: RenderPoint(x: 5, y: 5), radius: 4), color: .cyan)
    #expect(ShapeMesher.mesh(cmd) == ShapeMesher.mesh(cmd))
}

// MARK: - SceneCompiler

private func square(_ layer: RenderLayer, color: RenderColor = .white) -> DrawCommand {
    .shape(ShapeCommand(geometry: .rect(RenderRect(x: 0, y: 0, width: 10, height: 10), corner: 0),
                        color: color, layer: layer))
}

@Test func compilerPreservesSubmissionOrderRegardlessOfLayer() {
    var scene = Scene()
    scene.append(square(.ui, color: RenderColor(1, 0, 0)))
    scene.append(square(.background, color: RenderColor(0, 1, 0)))
    scene.append(square(.actors, color: RenderColor(0, 0, 1)))
    let frame = SceneCompiler.compile(scene, canvas: RenderSize(width: 100, height: 100),
                                      framebuffer: RenderSize(width: 100, height: 100))
    // All shapes, one contiguous run -> a single draw.
    #expect(frame.draws.count == 1)
    if case .shapes(let range, _) = frame.draws[0] {
        #expect(range == 0..<18)       // 3 rects * 6 verts
    } else {
        Issue.record("expected a shapes draw")
    }
    // A rectangle emits six vertices. Colour is interleaved after x/y, so the
    // first vertex of each rectangle proves the compiler retained submission
    // order instead of sorting by RenderLayer.
    #expect(Array(frame.shapeVertices[2..<6]) == [1, 0, 0, 1])
    #expect(Array(frame.shapeVertices[38..<42]) == [0, 1, 0, 1])
    #expect(Array(frame.shapeVertices[74..<78]) == [0, 0, 1, 1])
}

@Test func spriteBreaksTheShapeRun() {
    var scene = Scene()
    scene.append(square(.background))
    scene.append(.sprite(SpriteCommand(texture: TextureID(1),
                                       destination: RenderRect(x: 0, y: 0, width: 50, height: 50),
                                       layer: .background)))
    scene.append(square(.ui))
    let frame = SceneCompiler.compile(scene, canvas: RenderSize(width: 100, height: 100),
                                      framebuffer: RenderSize(width: 100, height: 100))
    #expect(frame.draws.count == 3)
    guard case .shapes = frame.draws[0] else { Issue.record("0: shapes"); return }
    guard case .sprite(let tex, let r, _) = frame.draws[1] else { Issue.record("1: sprite"); return }
    #expect(tex == TextureID(1))
    #expect(r == 0..<6)                 // one quad
    guard case .shapes = frame.draws[2] else { Issue.record("2: shapes"); return }
}

@Test func clipChangeSplitsShapeDraws() {
    var scene = Scene()
    scene.append(square(.ui))
    scene.append(.shape(ShapeCommand(
        geometry: .rect(RenderRect(x: 0, y: 0, width: 10, height: 10), corner: 0),
        color: .white, layer: .ui, clip: RenderRect(x: 0, y: 0, width: 5, height: 5))))
    let frame = SceneCompiler.compile(scene, canvas: RenderSize(width: 100, height: 100),
                                      framebuffer: RenderSize(width: 200, height: 200))
    #expect(frame.draws.count == 2)
    if case .shapes(_, let scissor) = frame.draws[1] {
        #expect(scissor == PixelRect(x: 0, y: 0, width: 10, height: 10))   // 5pt * 2x dpr
    } else {
        Issue.record("expected scissored shapes")
    }
}

@Test func ndcConversionPutsOriginTopLeft() {
    var scene = Scene()
    scene.append(.shape(ShapeCommand(
        geometry: .triangles([0, 0, 100, 0, 0, 100]), color: .white, layer: .ui)))
    let frame = SceneCompiler.compile(scene, canvas: RenderSize(width: 100, height: 100),
                                      framebuffer: RenderSize(width: 100, height: 100))
    // logical (0,0) -> NDC (-1, 1)
    #expect(abs(frame.shapeVertices[0] - -1) < 1e-4)
    #expect(abs(frame.shapeVertices[1] - 1) < 1e-4)
}

@Test func spriteVerticesCarryUVs() {
    var scene = Scene()
    scene.append(.sprite(SpriteCommand(texture: TextureID(7),
                                       destination: RenderRect(x: 0, y: 0, width: 100, height: 100),
                                       layer: .background)))
    let frame = SceneCompiler.compile(scene, canvas: RenderSize(width: 100, height: 100),
                                      framebuffer: RenderSize(width: 100, height: 100))
    #expect(frame.spriteVertices.count == 6 * 8)      // 2 tris * 8 floats
    // first vertex: pos(-1,1) uv(0,0)
    #expect(abs(frame.spriteVertices[2] - 0) < 1e-4)
    #expect(abs(frame.spriteVertices[3] - 0) < 1e-4)
}

@Test func textUsesGlyphAtlasWhenFontBookHasTheRole() {
    let atlas = FontAtlas(
        texture: TextureID(61), atlasWidth: 256, atlasHeight: 128, pixelSize: 64,
        ascent: 50, descent: 14, lineHeight: 70,
        glyphs: [
            "A": GlyphBox(x: 0, y: 0, w: 40, h: 44, advance: 44, left: 2, top: 44),
            "H": GlyphBox(x: 40, y: 0, w: 40, h: 44, advance: 44, left: 2, top: 44),
        ])
    let book = FontBook(atlases: [.ui: atlas])
    var scene = Scene()
    scene.append(.text(TextCommand(string: "AH", origin: RenderPoint(x: 10, y: 10), scale: 2, color: .white, font: .ui)))

    let withAtlas = SceneCompiler.compile(scene, canvas: RenderSize(width: 200, height: 200),
                                          framebuffer: RenderSize(width: 200, height: 200), fonts: book)
    #expect(withAtlas.fontVertices.count == 2 * 6 * 14)    // 2 glyphs, 2 tris, 14 floats
    #expect(withAtlas.spriteVertices.isEmpty)
    #expect(withAtlas.shapeVertices.isEmpty)               // nothing went to the vector path
    if case .font(let tex, _, _) = withAtlas.draws.first { #expect(tex == TextureID(61)) } else { Issue.record("expected a font draw") }

    // no FontBook → falls back to the vector font (shape vertices, no sprites)
    let vector = SceneCompiler.compile(scene, canvas: RenderSize(width: 200, height: 200),
                                       framebuffer: RenderSize(width: 200, height: 200))
    #expect(vector.spriteVertices.isEmpty)
    #expect(vector.fontVertices.isEmpty)
    #expect(!vector.shapeVertices.isEmpty)
}

@Test func atlasTextWithOutlineRemainsOneDraw() {
    let atlas = FontAtlas(
        texture: TextureID(61), atlasWidth: 256, atlasHeight: 128, pixelSize: 64,
        ascent: 50, descent: 14, lineHeight: 70,
        glyphs: ["A": GlyphBox(x: 0, y: 0, w: 40, h: 44, advance: 44, left: 2, top: 44)])
    let book = FontBook(atlases: [.ui: atlas])
    var scene = Scene()
    scene.append(.text(TextCommand(string: "A", origin: RenderPoint(x: 10, y: 10), scale: 2,
                                   color: .white, outline: 3, outlineColor: .black, font: .ui)))
    let frame = SceneCompiler.compile(scene, canvas: RenderSize(width: 100, height: 100),
                                      framebuffer: RenderSize(width: 100, height: 100), fonts: book)
    #expect(frame.draws.count == 1)
    #expect(frame.fontVertices.count == 6 * 14)
    // The final per-vertex float is a responsive, cap-height-relative stroke.
    #expect(abs(frame.fontVertices[12] - 2.8) < 0.001)
}

// MARK: - SceneBuilder

@Test func builderLayerScopingRestores() {
    var b = SceneBuilder(size: RenderSize(width: 100, height: 100))
    b.circle(center: RenderPoint(x: 1, y: 1), radius: 1, color: .white)          // .ui default
    b.inLayer(.actors) { $0.circle(center: RenderPoint(x: 2, y: 2), radius: 1, color: .white) }
    b.circle(center: RenderPoint(x: 3, y: 3), radius: 1, color: .white)          // back to .ui
    #expect(b.scene.commands.map(\.layer) == [.ui, .actors, .ui])
}

@Test func builderMeshAppliesPoseThenAmbientTransform() {
    var b = SceneBuilder(size: RenderSize(width: 100, height: 100))
    b.transformed(by: .translation(x: 10, y: 0)) {
        $0.mesh([0, 0, 1, 0, 0, 1], color: .white, pose: .translation(x: 1, y: 2), layer: .actors)
    }
    guard case .shape(let s) = b.scene.commands[0] else { Issue.record("shape"); return }
    let p = s.transform.apply(RenderPoint(x: 0, y: 0))
    #expect(p.x == 11 && p.y == 2)
}

@Test func builderTextSizeCentersBothAxes() {
    var b = SceneBuilder(size: RenderSize(width: 100, height: 100))
    b.text("label", at: RenderPoint(x: 10, y: 20), scale: 1, color: .white,
            centeredIn: RenderSize(width: 80, height: 40))
    guard case .text(let command) = b.scene.commands[0] else {
        Issue.record("text")
        return
    }
    #expect(command.centeredWidth == 80)
    #expect(command.centeredHeight == 40)
}

@Test func builderRecordsStaticShaderMaterialAndResolvesItsRect() {
    let key = ShaderAssetKey("surface.test")!
    let parameters = ShaderParameterValues(values: [
        "amount": .float(0.75),
        "tint": .color(ShaderColor(red: 0.1, green: 0.2, blue: 0.3)),
    ])
    var b = SceneBuilder(size: RenderSize(width: 100, height: 50))
    b.material(key, texture: TextureID(42), in: RenderRect(x: 10, y: 5, width: 20, height: 10),
               parameters: parameters, layer: .vfx)

    guard case .material(let command) = b.scene.commands[0] else {
        Issue.record("material")
        return
    }
    #expect(command.asset == key)
    #expect(command.texture == TextureID(42))
    #expect(command.rect == RenderRect(x: 10, y: 5, width: 20, height: 10))
    #expect(command.parameters == parameters)
    #expect(command.layer == .vfx)

    let frame = SceneCompiler.compile(
        b.scene,
        canvas: RenderSize(width: 100, height: 50),
        framebuffer: RenderSize(width: 200, height: 100)
    )
    #expect(frame.draws == [.material(index: 0)])
    #expect(frame.materials == [CompiledMaterialCommand(
        asset: key, texture: TextureID(42),
        rect: PixelRect(x: 20, y: 10, width: 40, height: 20),
        parameters: parameters, layer: .vfx
    )])
}

@Test func compiledMaterialKeepsOrderWithOtherDrawsWhileRendererSupportIsDeferred() {
    let key = ShaderAssetKey("surface.test")!
    var scene = Scene()
    scene.append(.sprite(SpriteCommand(
        texture: TextureID(1), destination: RenderRect(x: 0, y: 0, width: 10, height: 10), layer: .ui)))
    scene.append(.material(StaticShaderMaterialCommand(
        asset: key, texture: TextureID(2), rect: RenderRect(x: 10, y: 0, width: 10, height: 10), layer: .ui)))
    scene.append(.sprite(SpriteCommand(
        texture: TextureID(3), destination: RenderRect(x: 20, y: 0, width: 10, height: 10), layer: .ui)))

    let frame = SceneCompiler.compile(scene, canvas: RenderSize(width: 100, height: 100),
                                      framebuffer: RenderSize(width: 100, height: 100))
    #expect(frame.materials.count == 1)
    #expect(frame.draws.count == 3)
    guard case .sprite(let first, _, _) = frame.draws[0] else { Issue.record("first sprite"); return }
    #expect(first == TextureID(1))
    #expect(frame.draws[1] == .material(index: 0))
    guard case .sprite(let last, _, _) = frame.draws[2] else { Issue.record("last sprite"); return }
    #expect(last == TextureID(3))
}
