import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct XMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        AnyCodableRegistryMacro.self,
    ]
}
