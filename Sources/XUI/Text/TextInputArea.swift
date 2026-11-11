import Foundation

/// Wraps an app's content so that, while a text field has focus, the XUI
/// on-screen keyboard rises from the bottom and the content makes room for it.
///
/// The keyboard is drawn by XUI itself: it appears on the very frame a field is
/// focused (no OS keyboard to wait for), takes only the share of the screen its
/// shape needs, and never covers the field being edited as long as the field
/// is in the part of the content that remains.
public struct TextInputArea<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never

    let style: KeyboardStyle
    let content: Content

    public init(style: KeyboardStyle = KeyboardStyle(), @XViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let focusStore = _EnvironmentObjectContext.currentOrEmpty.object(TextFocusStore.self)
        let presence = store.box(for: id.child(type: KeyboardPresence.self)) { KeyboardPresence() }.value
        let keyboard = store.box(for: id.child(type: KeyboardRuntime.self)) { KeyboardRuntime() }.value

        let field = focusStore.flatMap { $0.wantsKeyboard ? $0.focusedField : nil }
        let progress = presence.advance(toward: field != nil, clock: store.clock, previousFrame: store.previousFrameClock)
        if field != nil ? progress < 1 : progress > 0 { store.requireLayoutNextFrame() }
        if let field { presence.lastField = field }

        let contentNode = LayoutNode(
            layout: PassthroughLayout(),
            children: await lower(content, id: id.child(type: Content.self), store: store)
        )
        var children = [contentNode]
        let shown = field ?? (progress > 0 ? presence.lastField : nil)
        if let shown {
            let style = style
            let node = LayoutNode(layout: KeyboardLayoutNode())
            node.draw = { rect, context in
                // Read at draw time: the container size is settled by this frame's place pass.
                keyboard.draw(rect: rect, field: shown, container: presence.container, context: context, style: style, store: focusStore)
            }
            children.append(node)
        }
        let kind = shown?.kind
        return [LayoutNode(
            layout: TextInputAreaLayout(presence: presence, progress: progress, numberPad: kind == .number),
            children: children
        )]
    }
}

/// Slide-in progress of the keyboard, eased over ~170 ms.
final class KeyboardPresence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    private var lastClock: Double?
    private var storedContainer = Size(width: 0, height: 0)
    var lastField: TextFocusStore.Field?

    static let duration = 0.17

    var container: Size {
        get { lock.withLock { storedContainer } }
        set { lock.withLock { storedContainer = newValue } }
    }

    /// Moves toward shown/hidden with the presentation clock and returns the eased progress.
    func advance(toward shown: Bool, clock: Double, previousFrame: Double?) -> Double {
        lock.withLock {
            let dt = lastClock.map { min(max(0, clock - max($0, previousFrame ?? $0)), 0.1) } ?? 0
            lastClock = clock
            let step = dt / Self.duration
            value = shown ? min(1, value + step) : max(0, value - step)
            // Appearing for the first frame still shows something at once.
            if shown, value == 0 { value = 0.001 }
            let t = value
            return 1 - (1 - t) * (1 - t) * (1 - t)
        }
    }
}

/// Places the content above the keyboard and the keyboard along the bottom edge,
/// sliding it up by `progress`.
struct TextInputAreaLayout: NodeLayout {
    let presence: KeyboardPresence
    let progress: Double
    let numberPad: Bool

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        proposal.resolved(fallback: context.referenceSize)
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        presence.container = rect.size
        guard let content = children.first else { return }
        let metrics = KeyboardMetrics.compute(container: rect.size, rowCount: 4, numberPad: numberPad)
        let inset = metrics.height * progress
        let contentRect = Rect(x: rect.x, y: rect.y, width: rect.width, height: max(0, rect.height - inset))
        content.frame = contentRect
        if children.count > 1 {
            // The keyboard node spans the strip it occupies; its draw reads `rect.y` to know how far it has risen.
            children[1].frame = Rect(x: rect.x, y: rect.maxY - inset, width: rect.width, height: metrics.height)
        }
    }
}

struct KeyboardLayoutNode: NodeLayout {
    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        proposal.resolved(fallback: Size(width: 10, height: 10))
    }
    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {}
}
