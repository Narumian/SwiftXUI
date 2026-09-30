import Foundation

/// Opts a composite `FX`/`XView` into `@XState`. `_installState` wires each
/// `@XState` property to its identity-keyed box; the walk (`lower(_:)`,
/// `emit(_:)`) calls it on a mutable copy before reading `body`. Shared by
/// both DSLs — neither refines `XView` nor `FX`, checked via `as?` against
/// an already-known `any XView`/`any FX`, the same idiom `_PrimitiveXView`/
/// `IntrinsicView` already use in this codebase.
public protocol _Stateful {
    mutating func _installState(id: StateIdentity, store: StateStore)
}

/// Sugar for hand-writing `_installState` — attach to a composite `FX`/
/// `XView` struct with one or more `@XState` properties. Generates the
/// `_Stateful` conformance and the `_installState` body (one `_install`
/// call per `@XState` property, found by name).
@attached(extension, conformances: _Stateful)
@attached(member, names: named(_installState))
public macro Stateful() = #externalMacro(module: "XUIMacros", type: "StatefulMacro")
