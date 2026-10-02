import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct AnyCodableRegistryMacro: ExtensionMacro, MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(EnumDeclSyntax.self) else {
            throw MacroExpansionErrorMessage(
                "@AnyCodableRegistry can only be attached to an enum"
            )
        }

        return [
            try ExtensionDeclSyntax(
                "extension \(type.trimmed): AnyCodableCatalog {}"
            )
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(EnumDeclSyntax.self) else {
            throw MacroExpansionErrorMessage(
                "@AnyCodableRegistry can only be attached to an enum"
            )
        }

        let types = try typeExpressions(from: node)
        let registry = types
            .map(\.trimmedDescription)
            .joined(separator: ", ")

        return [
            "public static let registry: [any AnyCodable.Type] = [\(raw: registry)]"
        ]
    }

    private static func typeExpressions(
        from node: AttributeSyntax
    ) throws -> [ExprSyntax] {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
              arguments.count == 1,
              let array = arguments.first?.expression.as(ArrayExprSyntax.self)
        else {
            throw MacroExpansionErrorMessage(
                "@AnyCodableRegistry expects an array, e.g. `[Foo.self, Bar.self]`"
            )
        }

        guard !array.elements.isEmpty else {
            throw MacroExpansionErrorMessage(
                "@AnyCodableRegistry requires at least one type"
            )
        }

        return array.elements.map(\.expression)
    }
}
