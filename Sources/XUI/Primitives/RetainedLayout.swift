/// A fixed-size visual subtree whose layout is reused between frames. Its
/// children are offered `size` and positioned from the top-leading corner.
///
/// Use for content without its own state or per-frame registration, such as a
/// label, background, and `DrawLayer`. Keep input modifiers outside the
/// subtree. Change `revision` when values captured by the subtree change,
/// including environment values it depends on. `DrawLayer` can read live data
/// when it paints; its size and the rest of the layout must stay independent
/// of that data.
public struct RetainedLayout<Revision: Equatable & Sendable, Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never

    private let size: Size
    private let revision: Revision
    private let content: @Sendable () -> Content

    public init(size: Size, revision: Revision, @XViewBuilder content: @escaping @Sendable () -> Content) {
        self.size = size
        self.revision = revision
        self.content = content
    }

    private struct LayoutKey: Equatable {
        let revision: Revision
        let frame: Rect
        let canvas: Size
        let measurementRevision: UInt64
        let direction: LayoutDirection
        let insets: EdgeInsets
    }

    private struct Entry {
        let key: LayoutKey
        let children: [LayoutNode]
    }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let cache = store.box(for: id.child(type: Self.self)) { nil as Entry? }
        let node = LayoutNode(layout: FixedSizeLayout(size: size))
        node.lazyChildrenArePlaced = true
        node.lazyChildren = { frame, context in
            let key = context.measurementRevision.map {
                LayoutKey(revision: revision, frame: frame, canvas: context.referenceSize,
                          measurementRevision: $0, direction: context.environment.layoutDirection,
                          insets: context.environment.safeAreaInsets)
            }
            if let key, let entry = cache.value, entry.key == key {
                if XViewProfiler.isEnabled { XViewProfiler.recordCount("retained_layout_hit", type: "RetainedLayout") }
                return entry.children
            }

            if XViewProfiler.isEnabled { XViewProfiler.recordCount("retained_layout_miss", type: "RetainedLayout") }
            let subtreeStore = StateStore()
            subtreeStore.beginPass(now: context.environment.fxTime)
            defer { subtreeStore.endPass() }
            let children = await lower(content(), id: id, store: subtreeStore)
            let root = LayoutNode(layout: RootLayout(), children: children)
            await LayoutEngine.place(root, in: frame, context)
            let placed = [root]
            cache.value = key.map { Entry(key: $0, children: placed) }
            return placed
        }
        return [node]
    }
}
