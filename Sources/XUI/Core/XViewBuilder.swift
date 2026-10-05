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

    public static func buildBlock<Content: X3DProgram>(_ content: Content) -> Content {
        content
    }

    public static func buildBlock<First: XView, Second: XView, each Rest: XView>(
        _ first: First, _ second: Second, _ rest: repeat each Rest
    ) -> TupleView {
        var children: [any XView] = [first, second]
        func append<V: XView>(_ view: V) { children.append(view) }
        repeat append(each rest)
        return TupleView(children)
    }

    public static func buildBlock<First: X3DProgram, Second: X3DProgram, each Rest: X3DProgram>(
        _ first: First, _ second: Second, _ rest: repeat each Rest
    ) -> TupleX3D {
        var children: [any X3DProgram] = [first, second]
        func append<P: X3DProgram>(_ program: P) { children.append(program) }
        repeat append(each rest)
        return TupleX3D(children)
    }

    public static func buildExpression<P: X3DProgram>(_ expression: P) -> P { expression }

    public static func buildOptional<P: X3DProgram>(_ content: P?) -> OptionalView<P> {
        OptionalView(content)
    }

    public static func buildEither<T: X3DProgram, F: X3DProgram>(first: T) -> ConditionalView<T, F> {
        ConditionalView(storage: .first(first))
    }

    public static func buildEither<T: X3DProgram, F: X3DProgram>(second: F) -> ConditionalView<T, F> {
        ConditionalView(storage: .second(second))
    }

    public static func buildArray<P: X3DProgram>(_ components: [P]) -> ArrayView<P> {
        ArrayView(components)
    }

    public static func buildLimitedAvailability<P: X3DProgram>(_ component: P) -> P { component }
}
