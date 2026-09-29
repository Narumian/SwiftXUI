import Foundation

/// Result builder for `body` and every container's content closure.
///
/// `buildBlock` is: identity for a single child (this is also what lets
/// `Never: XView` satisfy the `@XViewBuilder`'d requirement), and a value
/// parameter pack for two or more — one overload for any arity, no
/// `buildBlock2 / buildBlock3 / …` ladder.
@resultBuilder
public enum XViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }

    public static func buildBlock<Content: XView>(_ content: Content) -> Content {
        content
    }

    public static func buildBlock<each Content: XView>(
        _ content: repeat each Content
    ) -> TupleView {
        var children: [any XView] = []
        func append<V: XView>(_ view: V) { children.append(view) }
        repeat append(each content)
        return TupleView(children)
    }

    public static func buildExpression<V: XView>(_ expression: V) -> V { expression }

    public static func buildOptional<V: XView>(_ content: V?) -> OptionalView<V> {
        OptionalView(content)
    }

    public static func buildEither<T: XView, F: XView>(first: T) -> ConditionalView<T, F> {
        ConditionalView(storage: .first(first))
    }

    public static func buildEither<T: XView, F: XView>(second: F) -> ConditionalView<T, F> {
        ConditionalView(storage: .second(second))
    }

    public static func buildArray<V: XView>(_ components: [V]) -> ArrayView<V> {
        ArrayView(components)
    }

    public static func buildLimitedAvailability<V: XView>(_ component: V) -> V { component }
}
