import Foundation

/// Result builder for `FX.body` — the same shape as `XViewBuilder`: identity
/// for a single child, a value parameter pack for any larger arity.
@resultBuilder
public enum FXBuilder {
    public static func buildBlock() -> EmptyFX { EmptyFX() }

    public static func buildBlock<Content: FX>(_ content: Content) -> Content { content }

    public static func buildBlock<each Content: FX>(_ content: repeat each Content) -> TupleFX {
        var children: [any FX] = []
        func append<V: FX>(_ fx: V) { children.append(fx) }
        repeat append(each content)
        return TupleFX(children)
    }

    public static func buildExpression<V: FX>(_ expression: V) -> V { expression }

    public static func buildOptional<V: FX>(_ content: V?) -> OptionalFX<V> { OptionalFX(content) }

    public static func buildEither<T: FX, F: FX>(first: T) -> ConditionalFX<T, F> {
        ConditionalFX(storage: .first(first))
    }

    public static func buildEither<T: FX, F: FX>(second: F) -> ConditionalFX<T, F> {
        ConditionalFX(storage: .second(second))
    }

    public static func buildArray<V: FX>(_ components: [V]) -> ArrayFX<V> { ArrayFX(components) }
}

/// A builder aggregate whose direct children are the steps a composer such as
/// a sequence should treat as units. `TupleFX` and `ArrayFX` conform.
public protocol _FXGrouping {
    var _steps: [any FX] { get }
}

/// An empty run of effects.
public struct EmptyFX: FX, _PrimitiveFX {
    public typealias Body = Never
    public init() {}
    public func _emit(id: StateIdentity, store: StateStore, into out: inout [any FX]) {}
}

/// The output of a multi-statement `@FXBuilder` block. Children are erased to
/// `[any FX]` at the builder boundary — one shallow level, exactly where
/// `XView`'s `TupleView` allows it too. Each child gets its own identity,
/// keyed by its position among its siblings, so `@XState` inside two sibling
/// composites never aliases.
public struct TupleFX: FX, _PrimitiveFX, _FXGrouping {
    public typealias Body = Never
    let children: [any FX]
    public var _steps: [any FX] { children }
    init(_ children: [any FX]) { self.children = children }
    public func _emit(id: StateIdentity, store: StateStore, into out: inout [any FX]) {
        for (i, child) in children.enumerated() {
            emit(child, id: id.child(type: type(of: child), index: i), store: store, into: &out)
        }
    }
}

/// The output of an `if` with no `else`.
public struct OptionalFX<Wrapped: FX>: FX, _PrimitiveFX {
    public typealias Body = Never
    let wrapped: Wrapped?
    init(_ wrapped: Wrapped?) { self.wrapped = wrapped }
    public func _emit(id: StateIdentity, store: StateStore, into out: inout [any FX]) {
        if let wrapped { emit(wrapped, id: id, store: store, into: &out) }
    }
}

/// The output of an `if / else`.
public struct ConditionalFX<TrueContent: FX, FalseContent: FX>: FX, _PrimitiveFX {
    public typealias Body = Never
    enum Storage {
        case first(TrueContent)
        case second(FalseContent)
    }
    let storage: Storage
    public func _emit(id: StateIdentity, store: StateStore, into out: inout [any FX]) {
        switch storage {
        case .first(let fx): emit(fx, id: id, store: store, into: &out)
        case .second(let fx): emit(fx, id: id, store: store, into: &out)
        }
    }
}

/// The output of `buildArray` — a `for` loop in a builder block. Identity is
/// keyed by array position — stable as long as the loop's source collection
/// doesn't reorder, the same positional-identity caveat `XView`'s `ForEach`
/// documents.
public struct ArrayFX<Element: FX>: FX, _PrimitiveFX, _FXGrouping {
    public typealias Body = Never
    let elements: [Element]
    public var _steps: [any FX] { elements }
    init(_ elements: [Element]) { self.elements = elements }
    public func _emit(id: StateIdentity, store: StateStore, into out: inout [any FX]) {
        for (i, element) in elements.enumerated() {
            emit(element, id: id.child(type: Element.self, index: i), store: store, into: &out)
        }
    }
}
