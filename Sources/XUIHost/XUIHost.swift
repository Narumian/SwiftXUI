import XRender
import XUI

/// The high-level bridge from an XView tree to one renderer-neutral frame.
///
/// `XUIHost` owns the persistent `StateStore` and the concrete `SceneCanvas`.
/// Callers only provide the root view for each frame; the lower-level
/// `LayoutHost` and canvas plumbing stay behind this boundary.
public final class XUIHost: @unchecked Sendable {
    public var size: RenderSize
    public var background: RenderColor
    public var environment: EnvironmentValues
    public var fonts: FontBook?
    public var images: [ImageSource: TextureID]
    public var imageResolver: (@Sendable (ImageSource) -> TextureID?)?
    public let focusStore: FocusStore

    private let store = StateStore()
    private var gestureRuntime = GestureRuntime()
    private var lastFrame: XUIFrame?
    private var gamepadSource: GamepadInputSource?

    public init(
        size: RenderSize,
        background: RenderColor = RenderColor(0, 0, 0, 0),
        environment: EnvironmentValues = EnvironmentValues(),
        fonts: FontBook? = nil,
        images: [ImageSource: TextureID] = [:],
        imageResolver: (@Sendable (ImageSource) -> TextureID?)? = nil,
        focusStore: FocusStore = FocusStore()
    ) {
        self.size = size
        self.background = background
        self.environment = environment
        self.fonts = fonts
        self.images = images
        self.imageResolver = imageResolver
        self.focusStore = focusStore
    }

    /// Renders one XView declaration pass into a renderer-neutral frame.
    ///
    /// The returned `Scene` is intentionally still available as an escape
    /// hatch while the platform renderer boundary is being built. Normal app
    /// code should consume the frame through the eventual XUI application
    /// host instead of touching the scene directly.
    @discardableResult
    @XUIActor
    public func render<V: XView>(_ view: V, time: Double? = nil, x3dTime: Float = 0) async -> XUIFrame {
        var frameEnvironment = environment
        if let time { frameEnvironment.fxTime = time }
        frameEnvironment.environmentObject(focusStore)

        let surface = SceneCanvas(
            size: size,
            background: background,
            fonts: fonts,
            images: images,
            imageResolver: imageResolver
        )
        var layout = await LayoutHost(
            canvas: Size(width: Double(size.width), height: Double(size.height)),
            environment: frameEnvironment
        ).render(view, into: surface, store: store)
        layout.x3dTime = x3dTime

        focusStore.selectedID = FocusNavigator.selectInitial(
            in: layout.controls,
            current: focusStore.selectedID
        )
        let frame = XUIFrame(scene: surface.scene, layout: layout)
        lastFrame = frame
        return frame
    }

    /// Routes a renderer-neutral pointer sample through the current frame's
    /// XUI gesture regions.
    @discardableResult
    @XUIActor
    public func pointer(_ event: PointerEvent, in frame: XUIFrame) -> Bool {
        gestureRuntime.handle(
            PointerInput(
                id: event.id,
                phase: Self.pointerPhase(event.phase),
                position: Point(
                    x: Double(event.position.x),
                    y: Double(event.position.y)
                ),
                timestamp: event.timestamp
            ),
            in: frame.layout
        )
    }

    /// Routes a gamepad direction or button into the current focus tree.
    /// Render the host again after this call so the focus ring and any
    /// focus-driven ScrollView adjustment become visible.
    @discardableResult
    @XUIActor
    public func gamepad(_ input: GamepadInput, in frame: XUIFrame) -> Bool {
        switch input {
        case .direction(let direction):
            let next = FocusNavigator.next(
                from: focusStore.selectedID,
                direction: direction,
                controls: frame.layout.controls
            )
            guard let next, next != focusStore.selectedID else { return false }
            focusStore.selectedID = next
            return true

        case .confirm:
            guard
                let selectedID = focusStore.selectedID,
                let selected = frame.layout.controls.first(where: { $0.control.id == selectedID })
            else { return false }
            return frame.layout.tap(Point(x: selected.rect.midX, y: selected.rect.midY))

        case .back:
            return false
        }
    }

    /// Starts a native GameController input source and routes its events to
    /// the most recently rendered frame. The next display-loop render shows
    /// the updated focus ring and scroll position.
    @XUIActor
    public func startGamepadInput() -> GamepadInputSource {
        gamepadSource?.stop()
        let source = GamepadInputSource()
        source.onInput = { [weak self] input in
            Task { @XUIActor [weak self] in
                guard let self, let frame = self.lastFrame else { return }
                _ = self.gamepad(input, in: frame)
            }
        }
        source.start()
        gamepadSource = source
        return source
    }

    @XUIActor
    public func stopGamepadInput() {
        gamepadSource?.stop()
        gamepadSource?.onInput = nil
        gamepadSource = nil
    }

    private static func pointerPhase(_ phase: PointerPhase) -> PointerInputPhase {
        switch phase {
        case .began: .began
        case .moved: .moved
        case .ended: .ended
        case .cancelled: .cancelled
        }
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
