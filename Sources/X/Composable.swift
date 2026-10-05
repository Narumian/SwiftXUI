//
//  Composable.swift
//  SwiftX
//
//  Created by Narumi Inada on 2026/10/02.
//


protocol ComposableDomain<Domain> {
    associatedtype Domain
}

public protocol Composable<Domain>: Sendable {
    associatedtype Domain
    associatedtype Body: Composable<Domain>

    @ComposableBuilder<Domain> var body: Body { get }

    func process(into output: inout Domain)
}



public extension Composable {
    func process(into output: inout Domain) {
        body.process(into: &output)
    }
}

public struct Empty<Domain>: Composable {
    public typealias Body = Empty<Domain>

    public init() {}

    public var body: Empty<Domain> { self }

    public func process(into output: inout Domain) {
    }
}

public struct Tuple2<
    Domain,
    First: Composable<Domain>,
    Second: Composable<Domain>
>: Composable {
    public typealias Body = Empty<Domain>

    public let first: First
    public let second: Second

    public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }

    public var body: Empty<Domain> { Empty() }

    public func process(into output: inout Domain) {
        first.process(into: &output)
        second.process(into: &output)
    }
}

public struct OptionalPart<Domain, Part: Composable<Domain>>: Composable {
    public typealias Body = Empty<Domain>

    public let part: Part?

    public init(_ part: Part?) {
        self.part = part
    }

    public var body: Empty<Domain> { Empty() }

    public func process(into output: inout Domain) {
        part?.process(into: &output)
    }
}

public enum EitherPart<
    Domain,
    First: Composable<Domain>,
    Second: Composable<Domain>
>: Composable {
    public typealias Body = Empty<Domain>

    case first(First)
    case second(Second)

    public var body: Empty<Domain> { Empty() }

    public func process(into output: inout Domain) {
        switch self {
        case .first(let value):
            value.process(into: &output)
        case .second(let value):
            value.process(into: &output)
        }
    }
}

public struct Group<Domain>: Composable {
    public typealias Body = Empty<Domain>

    public let children: [any Composable<Domain>]

    public init(_ children: [any Composable<Domain>]) {
        self.children = children
    }

    public var body: Empty<Domain> { Empty() }

    public func process(into output: inout Domain) {
        for child in children {
            child.process(into: &output)
        }
    }
}



@resultBuilder
public enum ComposableBuilder<Domain> {
    public static func buildExpression<P: Composable<Domain>>(
        _ expression: P
    ) -> P {
        expression
    }

    public static func buildBlock() -> Empty<Domain> {
        Empty()
    }

    public static func buildBlock<P: Composable<Domain>>(
        _ part: P
    ) -> P {
        part
    }

    public static func buildBlock<
        First: Composable<Domain>,
        Second: Composable<Domain>
    >(
        _ first: First,
        _ second: Second
    ) -> Tuple2<Domain, First, Second> {
        Tuple2(first, second)
    }

    public static func buildOptional<P: Composable<Domain>>(
        _ part: P?
    ) -> OptionalPart<Domain, P> {
        OptionalPart(part)
    }

    public static func buildEither<
        First: Composable<Domain>,
        Second: Composable<Domain>
    >(
        first part: First
    ) -> EitherPart<Domain, First, Second> {
        .first(part)
    }

    public static func buildEither<
        First: Composable<Domain>,
        Second: Composable<Domain>
    >(
        second part: Second
    ) -> EitherPart<Domain, First, Second> {
        .second(part)
    }

    public static func buildArray<P: Composable<Domain>>(
        _ parts: [P]
    ) -> Group<Domain> {
        Group(parts.map { $0 as any Composable<Domain> })
    }
}
