import Foundation

public struct _ClipModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never

    let content: Content

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let node = LayoutNode(
            layout: PassthroughLayout(),
            children: lower(content, id: id.child(type: Content.self), store: store)
        )
        node.clipsToBounds = true
        return [node]
    }
}

public extension XView {
    /// Clip this rendered subtree to its resolved frame.
    func clipped() -> _ClipModifier<Self> {
        _ClipModifier(content: self)
    }

    /// Clip this rendered subtree to its resolved frame.
    ///
    /// The shape argument keeps call sites close to SwiftUI's style. The current
    /// renderer clip primitive is rectangular, so the rounded shape is accepted
    /// as the author's intent while clipping to the view's bounds.
    func clipped(_ shape: RoundedRectangle) -> _ClipModifier<Self> {
        _ClipModifier(content: self)
    }
}
