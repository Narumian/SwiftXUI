import Foundation

/// An empty run of content. Contributes no nodes.
public struct EmptyView: XView, _PrimitiveXView {
    public typealias Body = Never
    public init() {}
    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] { [] }
}

/// The output of a multi-statement `@XViewBuilder` block.
///
/// The children are erased to `[any XView]` at the builder boundary — one
/// shallow level, exactly where the plan says erasure is allowed. Every call
/// site stays fully type-checked (each child must be an `XView`); only the
/// aggregate loses its tuple type. This also keeps XUI buildable on
/// macOS 13 / iOS 16, where parameter packs in generic *types* are unavailable.
public struct TupleView: XView, _PrimitiveXView {
    public typealias Body = Never
    let children: [any XView]
    init(_ children: [any XView]) { self.children = children }
    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        var nodes: [LayoutNode] = []
        for (i, child) in children.enumerated() {
            nodes += await lower(child, id: id.child(type: type(of: child), index: i), store: store)
        }
        return nodes
    }
}

/// The output of an `if` with no `else` in a builder block.
public struct OptionalView<Wrapped: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let wrapped: Wrapped?
    init(_ wrapped: Wrapped?) { self.wrapped = wrapped }
    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        guard let wrapped else { return [] }
        return await lower(wrapped, id: id, store: store)
    }
}

/// The output of an `if / else` in a builder block.
public struct ConditionalView<TrueContent: XView, FalseContent: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    enum Storage {
        case first(TrueContent)
        case second(FalseContent)
    }
    let storage: Storage
    init(storage: Storage) { self.storage = storage }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        switch storage {
        case .first(let view): return await lower(view, id: id, store: store)
        case .second(let view): return await lower(view, id: id, store: store)
        }
    }
}

/// The output of `buildArray` — a `for` loop in a builder block, and the backing
/// for `ForEach`.
public struct ArrayView<Element: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let elements: [Element]
    init(_ elements: [Element]) { self.elements = elements }
    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        var nodes: [LayoutNode] = []
        for (i, element) in elements.enumerated() {
            nodes += await lower(element, id: id.child(type: type(of: element), index: i), store: store)
        }
        return nodes
    }
}
