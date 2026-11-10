import Foundation

/// A region of the screen the keyboard can be aimed at: a file tree, a grid. Pressing inside it aims the keyboard at it;
/// pressing anywhere else (or on a text field, a sheet) takes the aim away. `.keyboardShortcut(_:focusID:)` with the
/// same id then runs only while the area has it.
public struct KeyFocusArea: Hashable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

/// Which `KeyFocusArea` the keyboard is aimed at. Shared by the host (which moves it on a press), the shortcut table
/// (which consults it from the platform's key thread) and views (which show it). Lock-protected.
public final class KeyFocusStore: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String?

    public init() {}

    public var focusedID: String? { lock.withLock { current } }

    public func focus(_ id: String?) { lock.withLock { current = id } }

    public func isFocused(_ id: String) -> Bool { lock.withLock { current == id } }
}

public extension XView {
    /// Marks this view as an area the keyboard can be aimed at, by a press inside it.
    func keyFocusArea(id: String) -> _RegionModifier<Self> { region(KeyFocusArea(id: id)) }
}

/// Hands the id of the area the keyboard is aimed at to the content, without registering anything. Use it to draw a
/// focused look (a selection in the accent colour) on the area that has it.
public struct KeyFocusReader<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never

    let content: @XUIActor @Sendable (String?) -> Content

    public init(@XViewBuilder content: @XUIActor @escaping @Sendable (_ focused: String?) -> Content) {
        self.content = content
    }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let focused = _EnvironmentObjectContext.currentOrEmpty.object(KeyFocusStore.self)?.focusedID
        let node = LayoutNode(
            layout: PassthroughLayout(),
            children: await lower(content(focused), id: id.child(type: Content.self), store: store)
        )
        return [node]
    }
}
