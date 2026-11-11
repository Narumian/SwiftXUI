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
    public var environment: EnvironmentValues {
        didSet { environmentRevision &+= 1 }
    }
    public var fonts: FontBook? {
        didSet { if fonts != oldValue { measurementRevision &+= 1 } }
    }
    public var images: [ImageSource: TextureID]
    public var imageResolver: (@Sendable (ImageSource) -> TextureID?)?
    public let focusStore: FocusStore
    /// Which text field has the keyboard. Shared with every `TextField` in the tree.
    public let textFocus: TextFocusStore
    /// Which drag is under way, and the context menu. Shared with every draggable view in the tree.
    public let dragDrop: DragDropStore
    /// The `.keyboardShortcut`s of the frame on screen.
    public let shortcuts = KeyShortcutTable()
    /// Which `.keyFocusArea` the keyboard is aimed at; a press inside an area aims it there.
    public var keyFocus: KeyFocusStore { shortcuts.keyFocus }
    /// Where copy / cut / paste go. The platform shell replaces this with the system pasteboard.
    public var clipboard: any XClipboard = InMemoryClipboard()

    private let store = StateStore(tracksLayoutChanges: true)
    private var measurementRevision: UInt64 = 0
    private var environmentRevision: UInt64 = 0
    private var inputRevision: UInt64 = 0
    private struct LayoutKey: Equatable {
        let rootType: ObjectIdentifier
        let size: RenderSize
        let measurement: UInt64
        let environment: UInt64
        let state: UInt64
        let input: UInt64
        let application: UInt64
        let textFocus: Int
        let keyboardPolicy: KeyboardPolicy
        let focus: ControlID?
        let keyFocus: String?
    }
    private var placedLayout: (key: LayoutKey, root: LayoutHost.PlacedRoot)?
    /// Slop is in logical canvas units. A phone shows the canvas at about 0.36pt per unit, so the
    /// 10-unit default is under 4pt of finger travel and a plain tap reads as a drag.
    private var gestureRuntime = GestureRuntime(tapSlop: 24)
    private var lastFrame: XUIFrame?
    private var gamepadSource: GamepadInputSource?

    public init(
        size: RenderSize,
        background: RenderColor = RenderColor(0, 0, 0, 0),
        environment: EnvironmentValues = EnvironmentValues(),
        fonts: FontBook? = nil,
        images: [ImageSource: TextureID] = [:],
        imageResolver: (@Sendable (ImageSource) -> TextureID?)? = nil,
        focusStore: FocusStore = FocusStore(),
        textFocus: TextFocusStore = TextFocusStore(),
        dragDrop: DragDropStore = DragDropStore()
    ) {
        self.size = size
        self.background = background
        self.environment = environment
        self.fonts = fonts
        self.images = images
        self.imageResolver = imageResolver
        self.focusStore = focusStore
        self.textFocus = textFocus
        self.dragDrop = dragDrop
        textFocus.hostManagesFrames = true
        dragDrop.capturePointer = { [weak self] id in self?.gestureRuntime.cancel(pointerID: id) }
    }

    /// Renders one XView declaration pass into a renderer-neutral frame.
    ///
    /// The returned `Scene` is intentionally still available as an escape
    /// hatch while the platform renderer boundary is being built. Normal app
    /// code should consume the frame through the eventual XUI application
    /// host instead of touching the scene directly.
    @discardableResult
    @XUIActor
    public func render<V: XView>(_ view: V, time: Double? = nil) async -> XUIFrame {
        await render(time: time, layoutRevision: nil) { view }
    }

    @XUIActor
    func render<V: XView>(time: Double?, layoutRevision: UInt64?, view: @XUIActor () async -> V) async -> XUIFrame {
        var frameEnvironment = environment
        if let time { frameEnvironment.fxTime = time }
        frameEnvironment.environmentObject(focusStore)
        frameEnvironment.environmentObject(textFocus)
        frameEnvironment.environmentObject(dragDrop)
        frameEnvironment.environmentObject(keyFocus)
        dragDrop.beginFrame(clock: frameEnvironment.fxTime)

        let surface = SceneCanvas(
            size: size,
            background: background,
            fonts: fonts,
            images: images,
            imageResolver: imageResolver
        )
        textFocus.beginFrame()
        // Drag geometry and menu transitions depend on the presentation clock.
        // Discard those roots so a settled drag cannot leave a cached preview.
        let revision = dragDrop.isDragging || dragDrop.isMenuOpen ? nil : layoutRevision
        let key = revision.map {
            LayoutKey(rootType: ObjectIdentifier(V.self), size: size, measurement: measurementRevision,
                      environment: environmentRevision, state: store.layoutRevision, input: inputRevision,
                      application: $0, textFocus: textFocus.revision, keyboardPolicy: textFocus.keyboardPolicy,
                      focus: focusStore.selectedID, keyFocus: keyFocus.focusedID)
        }
        let previous = if let key, let placedLayout, placedLayout.key == key, !store.needsLayoutNextFrame {
            placedLayout.root
        } else {
            nil as LayoutHost.PlacedRoot?
        }
        let (layout, root) = await LayoutHost(
            canvas: Size(width: Double(size.width), height: Double(size.height)),
            environment: frameEnvironment,
            measurementRevision: measurementRevision
        ).render(into: surface, store: store, reusing: previous, view: view)
        // Save the key from before declaration so writes during an awaited
        // layout pass cause another pass instead of being marked consumed.
        placedLayout = key.map { ($0, root) }
        textFocus.endFrame()
        dragDrop.endFrame(layout)
        shortcuts.replace(with: layout.shortcuts)

        focusStore.selectedID = FocusNavigator.selectInitial(
            in: layout.controls,
            current: focusStore.selectedID
        )
        let frame = XUIFrame(scene: surface.scene, layout: layout,
                             stats: XUIFrameStats(measureCalls: surface.measureCalls, layoutPasses: previous == nil ? 1 : 0))
        lastFrame = frame
        return frame
    }

    @XUIActor
    func invalidateLayoutAfterInput() { inputRevision &+= 1 }

    /// Routes a renderer-neutral pointer sample through the current frame's
    /// XUI gesture regions.
    @discardableResult
    @XUIActor
    public func pointer(_ event: PointerEvent, in frame: XUIFrame) -> Bool {
        defer { invalidateLayoutAfterInput() }
        let position = Point(x: Double(event.position.x), y: Double(event.position.y))
        // A press outside every field and outside the keyboard dismisses the keyboard.
        if event.phase == .began { textFocus.blurIfOutside(position) }
        // The on-screen keyboard takes its own fingers (several can type at once) before gestures do.
        let input = PointerInput(
            id: event.id, phase: Self.pointerPhase(event.phase), position: position, timestamp: event.timestamp
        )
        if textFocus.handleKeyboardPointer(input) { return true }
        // A press aims the keyboard at the key focus area under it, or at none.
        if event.phase == .began { keyFocus.focus(frame.layout.hit(position, as: KeyFocusArea.self)?.id) }
        // A lifted drag owns its pointer; a press that might lift is only watched until it does.
        if dragDrop.handle(input, in: frame.layout) { return true }
        return gestureRuntime.handle(
            input,
            in: frame.layout
        )
    }

    /// Cancels the pointer sequence in progress (the app lost focus): a held `PressGesture` is told.
    @XUIActor
    public func cancelPointers() {
        gestureRuntime.cancelAll()
        invalidateLayoutAfterInput()
    }

    /// A secondary click (or the platform's long-press gesture for a menu) at `position`.
    @discardableResult
    @XUIActor
    public func contextClick(at position: RenderPoint) -> Bool {
        defer { invalidateLayoutAfterInput() }
        return dragDrop.contextClick(at: Point(x: Double(position.x), y: Double(position.y)))
    }

    /// Routes a gamepad direction or button into the current focus tree.
    /// Render the host again after this call so the focus ring and any
    /// focus-driven ScrollView adjustment become visible.
    @discardableResult
    @XUIActor
    public func gamepad(_ input: GamepadInput, in frame: XUIFrame) -> Bool {
        defer { invalidateLayoutAfterInput() }
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
    public let stats: XUIFrameStats

    public init(scene: Scene, layout: RenderResult, stats: XUIFrameStats = XUIFrameStats()) {
        self.scene = scene
        self.layout = layout
        self.stats = stats
    }
}

/// Counters from building one frame, for finding what a view costs.
public struct XUIFrameStats: Sendable, Equatable {
    /// Text-width requests made by layout and drawing.
    public var measureCalls = 0
    public var layoutPasses: Int
    public init(measureCalls: Int = 0, layoutPasses: Int = 0) {
        self.measureCalls = measureCalls
        self.layoutPasses = layoutPasses
    }
}
