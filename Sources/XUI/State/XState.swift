import Foundation

/// SwiftUI-`@State`-style persistent storage for a `body`-based `FX`/`XView`
/// composite. Requires an explicit type and default value — the macro reads
/// both from the property's own syntax (`@XState var glow: Float = 0`), since
/// there's no type-checking at macro-expansion time to infer them from.
///
/// Only legal inside a `@Stateful` type: `XStateMacro` refuses to expand
/// otherwise (checked via `context.lexicalContext`, since neither role can
/// see the enclosing type's other attributes any other way) — a plain
/// property wrapper couldn't run that check, which is why this is a macro
/// and not the struct-based design Stage 6 shipped.
///
/// Named `XState`, not `State` — a bare `@State` would collide with real
/// SwiftUI's `@State` in any file that imports both (this codebase already
/// has one: `BattleScenePreview.swift`).
@attached(accessor)
@attached(peer, names: arbitrary)
public macro XState() = #externalMacro(module: "XUIMacros", type: "XStateMacro")
