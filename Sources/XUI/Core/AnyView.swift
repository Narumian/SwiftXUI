/// A type-erased XView used at boundaries where the concrete view type is not
/// statically available, such as an existential application root.
public struct AnyView: XView, _PrimitiveXView {
    public typealias Body = Never

    private let view: any XView

    public init(_ view: any XView) {
        self.view = view
    }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        await lower(view, id: id, store: store)
    }
}
