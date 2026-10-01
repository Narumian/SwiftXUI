import Foundation

/// Injects an exact-type reference into the environment visible while
/// `content` is lowered. Descendants can read it with `@EnvironmentObject`.
public struct _EnvironmentModifier<Content: XView, Object: AnyObject>: XView, _PrimitiveXView {
    public typealias Body = Never

    let content: Content
    let object: Object

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let scoped = _EnvironmentObjectContext.currentOrEmpty.inserting(object)
        return await _EnvironmentObjectContext.$current.withValue(scoped) {
            await lower(content, id: id, store: store)
        }
    }
}

public extension XView {
    /// Makes `object` available to descendants through `@EnvironmentObject`.
    /// A later value of the same exact type replaces the earlier one.
    func environment<Object: AnyObject>(_ object: Object) -> _EnvironmentModifier<Self, Object> {
        _EnvironmentModifier(content: self, object: object)
    }
}
