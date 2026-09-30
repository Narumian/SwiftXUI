import XRender
import XUI
import XUISceneKit

/// The high-level bridge from an XView tree to one renderer-neutral frame.
///
/// `XUIHost` owns the persistent `StateStore` and the concrete `SceneCanvas`.
/// Callers only provide the root view for each frame; the lower-level
/// `LayoutHost` and canvas plumbing stay behind this boundary.
public final class XUIHost {
    public var size: RenderSize
    public var background: RenderColor
    public var environment: EnvironmentValues
    public var fonts: FontBook?
    public var images: [ImageSource: TextureID]

    private let store = StateStore()

    public init(
        size: RenderSize,
        background: RenderColor = RenderColor(0, 0, 0, 0),
        environment: EnvironmentValues = EnvironmentValues(),
        fonts: FontBook? = nil,
        images: [ImageSource: TextureID] = [:]
    ) {
        self.size = size
        self.background = background
        self.environment = environment
        self.fonts = fonts
        self.images = images
    }

    /// Renders one XView declaration pass into a renderer-neutral frame.
    ///
    /// The returned `Scene` is intentionally still available as an escape
    /// hatch while the platform renderer boundary is being built. Normal app
    /// code should consume the frame through the eventual XUI application
    /// host instead of touching the scene directly.
    @discardableResult
    public func render<V: XView>(_ view: V, time: Double? = nil) -> XUIFrame {
        var frameEnvironment = environment
        if let time { frameEnvironment.fxTime = time }

        let surface = SceneCanvas(
            size: size,
            background: background,
            fonts: fonts,
            images: images
        )
        let layout = LayoutHost(
            canvas: Size(width: Double(size.width), height: Double(size.height)),
            environment: frameEnvironment
        ).render(view, into: surface, store: store)

        return XUIFrame(scene: surface.scene, layout: layout)
    }
}

/// The result of one XUIHost declaration pass.
public struct XUIFrame {
    public let scene: Scene
    public let layout: RenderResult

    public init(scene: Scene, layout: RenderResult) {
        self.scene = scene
        self.layout = layout
    }
}
