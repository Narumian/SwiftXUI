import Testing
import XRender
@testable import XUI
@testable import XUIHost

@XUIActor
private func renderedSprite(_ view: some XView) async -> SpriteCommand? {
    let surface = SceneCanvas(size: RenderSize(width: 300, height: 200))
    await LayoutHost(canvas: Size(width: 300, height: 200)).render(view, into: surface)
    return surface.scene.commands.compactMap { command in
        if case .sprite(let sprite) = command { return sprite }
        return nil
    }.first
}

@Test @XUIActor func spriteImageReportsNaturalSizeWhenUnconstrained() async {
    let sprite = await renderedSprite(
        SpriteImage(TextureID(42), naturalSize: Size(width: 96, height: 48))
            .anchor("image")
    )

    #expect(sprite?.texture == TextureID(42))
    #expect(sprite?.destination == RenderRect(x: 0, y: 0, width: 96, height: 48))
}

@Test @XUIActor func spriteImageWorksWithScaledToFit() async {
    let sprite = await renderedSprite(
        SpriteImage(TextureID(7), naturalSize: Size(width: 160, height: 80))
            .resizable()
            .scaledToFit()
            .frame(width: 100, height: 100)
    )

    #expect(sprite?.destination == RenderRect(x: 0, y: 25, width: 100, height: 50))
}

@Test @XUIActor func spriteImageCarriesTintOpacityLayerAndSource() async {
    let source = RenderRect(x: 8, y: 9, width: 10, height: 11)
    let tint = RenderColor(1, 0.5, 0.25, 1)
    let sprite = await renderedSprite(
        SpriteImage(TextureID(5), naturalSize: Size(width: 40, height: 40), source: source)
            .resizable()
            .tint(tint)
            .opacity(0.6)
            .layer(.foreground)
            .frame(width: 20, height: 30)
    )

    #expect(sprite?.source == source)
    #expect(sprite?.tint == tint)
    #expect(sprite?.opacity == 0.6)
    #expect(sprite?.layer == .foreground)
    #expect(sprite?.destination == RenderRect(x: 0, y: 0, width: 20, height: 30))
}

@Test @XUIActor func coreImageCanResolveATextureThroughSceneCanvas() async {
    let source = ImageSource(TextureID(12), naturalSize: Size(width: 80, height: 40))
    let sprite = await renderedSprite(
        Image(source)
            .resizable()
            .scaledToFit()
            .frame(width: 100, height: 100)
    )

    #expect(sprite?.texture == TextureID(12))
    #expect(sprite?.destination == RenderRect(x: 0, y: 25, width: 100, height: 50))
}

@Test @XUIActor func coreImageCanResolveATextureFromSceneCanvasRegistry() async {
    let source = ImageSource("battle.hero", naturalSize: Size(width: 60, height: 30))
    let surface = SceneCanvas(size: RenderSize(width: 300, height: 200), images: [source: TextureID(99)])

    await LayoutHost(canvas: Size(width: 300, height: 200))
        .render(Image(source).frame(width: 100, height: 70), into: surface)

    let sprite = surface.scene.commands.compactMap { command in
        if case .sprite(let sprite) = command { return sprite }
        return nil
    }.first
    #expect(sprite?.texture == TextureID(99))
    #expect(sprite?.destination == RenderRect(x: 20, y: 20, width: 60, height: 30))
}
