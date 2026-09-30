import Testing
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
@testable import XUIMacros

private let macros: [String: Macro.Type] = ["XState": XStateMacro.self, "Stateful": StatefulMacro.self]

@Test func xStateExpandsAccessorsAndPeerStorageInsideAStatefulType() {
    assertMacroExpansion(
        """
        @Stateful
        struct PoisonAura {
            @XState var spawned: Bool = false
        }
        """,
        expandedSource: """
            struct PoisonAura {
                var spawned: Bool {
                    get {
                        _spawned?.value ?? false
                    }
                    nonmutating set {
                        _spawned?.value = newValue
                    }
                }

                private var _spawned: StateStore.Box<Bool>?

                var $spawned: Binding<Bool> {
                    Binding(
                        get: { _spawned?.value ?? false },
                        set: { _spawned?.value = $0 }
                    )
                }

                mutating func _installState(id: StateIdentity, store: StateStore) {
                        _spawned = store._xstateBox(id: id, name: "spawned", default: {
                                false
                            })
                }
            }

            extension PoisonAura: _Stateful {
            }
            """,
        macros: macros
    )
}

@Test func xStateWithoutStatefulIsACompileError() {
    assertMacroExpansion(
        """
        struct Oops {
            @XState var counter: Int = 0
        }
        """,
        expandedSource: """
            struct Oops {
                var counter: Int = 0
            }
            """,
        diagnostics: [
            DiagnosticSpec(
                message: "@XState requires the enclosing type to be @Stateful — state would silently never persist otherwise",
                line: 2,
                column: 5
            ),
            DiagnosticSpec(
                message: "@XState requires the enclosing type to be @Stateful — state would silently never persist otherwise",
                line: 2,
                column: 5
            ),
        ],
        macros: macros
    )
}
