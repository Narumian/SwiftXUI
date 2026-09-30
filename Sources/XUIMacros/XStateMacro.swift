import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@XState` — accessor macro (redirects `get`/`set` through a box) + peer
/// macro (the box reference itself needs somewhere to live between frames).
/// Both roles refuse to expand unless the enclosing type is `@Stateful` —
/// this is the actual point of the redesign: a property wrapper can't run
/// diagnostics, so this couldn't be a compile error before.
public struct XStateMacro: AccessorMacro, PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        try requireEnclosingStateful(context: context)
        let field = try field(in: declaration)

        return [
            AccessorDeclSyntax("get { _\(raw: field.name)?.value ?? \(field.defaultExpr) }"),
            // `nonmutating` — this only mutates the referenced `Box` class's
            // `value`, never `self`, matching Stage 6's `XState.wrappedValue`.
            AccessorDeclSyntax("nonmutating set { _\(raw: field.name)?.value = newValue }"),
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try requireEnclosingStateful(context: context)
        let field = try field(in: declaration)

        return [
            "private var _\(raw: field.name): StateStore.Box<\(field.type.trimmed)>?"
        ]
    }

    private struct Field {
        var name: String
        var type: TypeSyntax
        var defaultExpr: ExprSyntax
    }

    private static func field(in declaration: some DeclSyntaxProtocol) throws -> Field {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              let binding = variable.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
              let type = binding.typeAnnotation?.type,
              let defaultExpr = binding.initializer?.value
        else {
            throw MacroExpansionErrorMessage(
                "@XState requires an explicit type and a default value, e.g. `@XState var x: Bool = false`"
            )
        }
        return Field(name: identifier.text, type: type, defaultExpr: defaultExpr)
    }

    /// `context.lexicalContext` is innermost-first; the first `StructDeclSyntax`
    /// found is the type this property lives in. Its `attributes` survive the
    /// lexical-context stripping (only member lists/bodies are emptied).
    private static func requireEnclosingStateful(context: some MacroExpansionContext) throws {
        let isStateful = context.lexicalContext
            .compactMap { $0.as(StructDeclSyntax.self) }
            .first?
            .attributes
            .contains { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "Stateful" }
            ?? false

        guard isStateful else {
            throw MacroExpansionErrorMessage(
                "@XState requires the enclosing type to be @Stateful — state would silently never persist otherwise"
            )
        }
    }
}

@main
struct XUIMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        StatefulMacro.self,
        XStateMacro.self,
    ]
}
