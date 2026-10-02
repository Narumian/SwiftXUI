//
//  AnyCodable.swift
//  SwiftX
//

/// A common marker for values that can be stored in an `Aox` box.
public protocol AnyCodable: Codable {
    static var typeID: String { get }
}

public extension AnyCodable {
    static var typeID: String {
        String(describing: Self.self)
    }
}

/// A concrete catalog used by `Aox` to recreate erased values while decoding.
public protocol AnyCodableCatalog {
    static var registry: [any AnyCodable.Type] { get }
}

/// Generates an `AnyCodableCatalog` registry for a concrete catalog type.
///
/// Example:
///
///     @AnyCodableRegistry([Foo.self, Bar.self])
///     public enum TestCatalog {}
///
///     @Aox<TestCatalog>
///     var value: any AnyCodable
@attached(member, names: named(registry))
@attached(extension, conformances: AnyCodableCatalog)
public macro AnyCodableRegistry(_ types: [Any.Type]) = #externalMacro(
    module: "XMacros",
    type: "AnyCodableRegistryMacro"
)
