import Foundation

/// The resolved geometry of a `GeometryReader` slot.
///
/// `frame` is in the layout host's canvas coordinate space. `size` is kept as
/// a convenience for code that only needs the available dimensions.
public struct GeometryProxy: Sendable {
    public let frame: Rect

    public init(frame: Rect) {
        self.frame = frame
    }

    public var size: Size { frame.size }
    public var width: Double { frame.width }
    public var height: Double { frame.height }
}

/// Hands its resolved geometry to a content closure. Fills whatever it is
/// offered (like SwiftUI's `GeometryReader`) and pins its content top-leading.
///
/// This is the `GeometryReader { proxy in … }` escape valve — reach for it only
/// where a real pixel number is unavoidable; prefer stacks and `.frame`.
public struct GeometryReader<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: @Sendable (GeometryProxy) -> Content

    public init(@XViewBuilder content: @escaping @Sendable (GeometryProxy) -> Content) {
        self.content = content
    }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let node = LayoutNode(layout: GeometryReaderLayout())
        let build = content
        let environmentObjects = _EnvironmentObjectContext.current
        // `lazyChildren` fires later, from `LayoutEngine.place` — capture `id`/
        // `store` now since they aren't available at that call site.
        node.lazyChildren = { rect, _ in
            await _EnvironmentObjectContext.$current.withValue(environmentObjects) {
                await lower(build(GeometryProxy(frame: rect)), id: id, store: store)
            }
        }
        return [node]
    }
}

struct GeometryReaderLayout: NodeLayout {
    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        proposal.resolved(fallback: Size(width: 10, height: 10))
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        for child in children {
            let size = child.measure(ProposedSize(rect.size), context)
            child.frame = Rect(origin: rect.origin, size: size)
        }
    }
}
