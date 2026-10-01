import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ObservableActorMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let actor = declaration.as(ActorDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@ObservableActor can only be attached to an actor")
        }

        return storedProperties(in: actor).flatMap { field in
            [
                """
                var $\(raw: field.name): ActorBinding<\(raw: field.type)> {
                    ActorBinding(
                        get: { await self.\(raw: field.name) },
                        set: { await self._set_\(raw: field.name)($0) }
                    )
                }
                """,
                """
                private func _set_\(raw: field.name)(_ value: \(raw: field.type)) {
                    \(raw: field.name) = value
                }
                """
            ]
        }
    }

    private struct Field {
        let name: String
        let type: String
    }

    private static func storedProperties(in actor: ActorDeclSyntax) -> [Field] {
        actor.memberBlock.members.compactMap { member in
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  variable.bindingSpecifier.tokenKind == .keyword(.var),
                  !variable.modifiers.containsStaticOrClass,
                  let binding = variable.bindings.first,
                  binding.accessorBlock == nil,
                  let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                  let type = binding.typeAnnotation?.type
            else { return nil }

            return Field(name: identifier.identifier.text, type: type.trimmedDescription)
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
