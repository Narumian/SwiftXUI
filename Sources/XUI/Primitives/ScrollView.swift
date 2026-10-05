import Foundation

/// A vertically scrollable viewport.
///
/// The viewport takes the size offered by its parent. The content is measured
/// with an unspecified height so a `VStack` can grow beyond the viewport, then
/// translated and clipped while the user drags it.
public struct ScrollView<Content: XView>: XView {
    private let content: Content
    private let id: String

    public init(id: String = "default", @XViewBuilder content: () -> Content) {
        self.id = id
        self.content = content()
    }

    public var body: some XView {
        _ScrollViewState(id: id, content: content)
    }
}

@Stateful
private struct _ScrollViewState<Content: XView>: XView {
    let id: String
    let content: Content
    @XState private var offset: Double = 0
    @XState private var lastTranslation: Double = 0

    init(id: String, content: Content) {
        self.id = id
        self.content = content
    }

    var body: some XView {
        let offsetBox = _offset
        let translationBox = _lastTranslation
        let focusStore = _EnvironmentObjectContext.currentOrEmpty.object(FocusStore.self)
        let adjustedOffset = focusStore?.offsetToRevealSelected(in: id, current: offset) ?? offset
        _ScrollViewPrimitive(
            id: id,
            content: content,
            offset: adjustedOffset,
            dragChanged: { translation in
                guard let offsetBox, let translationBox else { return }
                let delta = translation - translationBox.value
                offsetBox.value -= delta
                translationBox.value = translation
            },
            dragEnded: {
                translationBox?.value = 0
            },
            normalizeOffset: { value in
                offsetBox?.value = value
            }
        )
    }
}

private struct _ScrollViewPrimitive<Content: XView>: XView, _PrimitiveXView {
    typealias Body = Never

    let id: String
    let content: Content
    let offset: Double
    let dragChanged: @Sendable (Double) -> Void
    let dragEnded: @Sendable () -> Void
    let normalizeOffset: @Sendable (Double) -> Void

    @XUIActor
    func _lower(id stateID: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let dragChanged = dragChanged
        let dragEnded = dragEnded
        let normalizeOffset = normalizeOffset
        let node = LayoutNode(
            layout: ScrollViewLayout(offset: offset, normalizeOffset: normalizeOffset),
            children: await lower(content, id: stateID, store: store)
        )
        node.clipsToBounds = true
        node.scrollViewportID = self.id
        node.dragGesture = DragGesture(minimumDistance: 8)
            .onChanged { value in dragChanged(value.translation.y) }
            .onEnded { _ in dragEnded() }
        return [node]
    }
}

/// Layout for a vertical scrolling viewport. Its child is intentionally
/// measured without a height proposal, while the viewport itself keeps the
/// parent's offered size.
struct ScrollViewLayout: NodeLayout {
    var offset: Double
    var normalizeOffset: @Sendable (Double) -> Void

    func sizeThatFits(
        _ proposal: ProposedSize,
        _ children: [LayoutNode],
        _ context: LayoutContext
    ) -> Size {
        guard let child = children.first else { return proposal.resolved() }
        let viewport = proposal.resolved(fallback: child.measure(.init(width: proposal.width, height: nil), context))
        _ = child.measure(ProposedSize(width: viewport.width, height: nil), context)
        return viewport
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        guard let child = children.first else { return }
        let contentSize = child.measure(ProposedSize(width: rect.width, height: nil), context)
        let maximumOffset = max(0, contentSize.height - rect.height)
        let shownOffset = min(max(0, offset), maximumOffset)
        normalizeOffset(shownOffset)
        child.frame = Rect(
            origin: Point(x: rect.x, y: rect.y - shownOffset),
            size: Size(width: rect.width, height: contentSize.height)
        )
    }
}
