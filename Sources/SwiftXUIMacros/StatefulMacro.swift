import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Stateful` → `extension T: _Stateful {}` plus a generated `_installState`
/// that wires each `@XState` property to its box. Mirrors
/// `GameSimulationMacros.DigestibleMacro`'s field-introspection shape
/// (`storedFieldNames(in:)`), narrowed to only properties carrying `@XState`.
public struct StatefulMacro: ExtensionMacro, MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@Stateful can only be attached to a struct")
        }

        return [
            try ExtensionDeclSyntax("extension \(type.trimmed): _Stateful {}")
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@Stateful can only be attached to a struct")
        }

        let fields = xStateFields(in: structDecl)
        let installs = fields
            .map { "        _\($0.name) = store._xstateBox(id: id, name: \"\($0.name)\", default: { \($0.defaultExpr) })" }
            .joined(separator: "\n")

        return [
            """
            mutating func _installState(id: StateIdentity, store: StateStore) {
            \(raw: installs)
            }
            """
        ]
    }

    private struct XStateField {
        var name: String
        var defaultExpr: String
    }

    /// Stored properties whose declaration carries an `@XState` attribute —
    /// unlike `DigestibleMacro.storedFieldNames`, this doesn't want every
    /// stored property, only the ones with persistent storage, and it needs
    /// each one's default-value expression to seed `_xstateBox`.
    private static func xStateFields(in structDecl: StructDeclSyntax) -> [XStateField] {
        structDecl.memberBlock.members.flatMap { member -> [XStateField] in
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.containsStaticOrClass,
                  variable.attributes.contains(where: {
                      $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "XState"
                  })
            else { return [] }

            return variable.bindings.compactMap { binding in
                guard binding.accessorBlock == nil,
                      let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                      let defaultExpr = binding.initializer?.value
                else { return nil }
                return XStateField(name: identifier.identifier.text, defaultExpr: "\(defaultExpr)")
            }
        }
    }
}

private extension DeclModifierListSyntax {
    var containsStaticOrClass: Bool {
        contains { modifier in
            let name = modifier.name.tokenKind
            return name == .keyword(.static) || name == .keyword(.class)
        }
    }
}
