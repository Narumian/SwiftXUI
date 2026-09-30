import Foundation

/// Expand a collection into sibling views. v1 has no identity / diffing — the
/// tree is rebuilt every frame — so no `id:` parameter; order is positional.
public struct ForEach<Data: RandomAccessCollection, Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let data: Data
    let content: (Data.Element) -> Content

    public init(_ data: Data, @XViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        var nodes: [LayoutNode] = []
        for (i, element) in data.enumerated() {
            nodes += await lower(content(element), id: id.child(type: Content.self, index: i), store: store)
        }
        return nodes
    }
}

public extension ForEach where Data == Range<Int> {
    init(_ range: Range<Int>, @XViewBuilder content: @escaping (Int) -> Content) {
        self.data = range
        self.content = content
    }
}
