import Foundation

/// A `GeometryReader` that also hands over the host's safe-area insets, read
/// from the environment at layout time.
public struct SafeAreaReader<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: @Sendable (GeometryProxy, EdgeInsets) -> Content

    public init(@XViewBuilder content: @escaping @Sendable (_ proxy: GeometryProxy, _ safeArea: EdgeInsets) -> Content) {
        self.content = content
    }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let node = LayoutNode(layout: GeometryReaderLayout())
        let build = content
        let environmentObjects = _EnvironmentObjectContext.current
        node.lazyChildren = { rect, context in
            let insets = context.environment.safeAreaInsets
            return await _EnvironmentObjectContext.$current.withValue(environmentObjects) {
                await lower(build(GeometryProxy(frame: rect), insets), id: id, store: store)
            }
        }
        return [node]
    }
}
