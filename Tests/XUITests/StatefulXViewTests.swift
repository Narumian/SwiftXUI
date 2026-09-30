import Testing
@testable import XUI

/// Proves `_Stateful`/`@XState` give a composite view a stable identity
/// across separate `render` calls through the same `StateStore` — first
/// render black, every later one red — and that a fresh `StateStore` is a
/// fresh scope, not a global leak. Hand-writes `_installState` (no
/// `@Stateful`) to prove the raw protocol contract, independent of whether
/// the macro generates it correctly — `StatefulMacroTests.swift` covers that.

private struct EntranceOnce: XView, _Stateful {
    // No `@XState` here on purpose — that macro refuses to expand without
    // `@Stateful` (the actual point of this redesign), so hand-writing the
    // raw `_Stateful` contract means hand-writing the box reference too.
    private var _spawned: StateStore.Box<Bool>?

    var body: some XView {
        Color(alreadyPlayed() ? .red : .black)
    }

    /// A bare `_spawned!.value = true` assignment can't sit inside `body` —
    /// the `@XViewBuilder` transform routes every statement in the block
    /// through `buildExpression`, which only accepts `XView` values (same
    /// reason `PoisonAura` needed this shape on the `FX` side).
    private func alreadyPlayed() -> Bool {
        defer { _spawned?.value = true }
        return _spawned?.value ?? false
    }

    mutating func _installState(id: StateIdentity, store: StateStore) {
        _spawned = store._xstateBox(id: id, name: "spawned", default: { false })
    }
}

private func firstFillColor(_ store: StateStore) -> XColorValue? {
    let surface = RecordingCanvas()
    LayoutHost(canvas: Size(width: 100, height: 100)).render(EntranceOnce(), into: surface, store: store)
    return surface.fills.first?.color
}

@Test func statefulXViewPlaysItsEntranceOnceThenRepeatsTheSteadyState() {
    let store = StateStore()
    #expect(firstFillColor(store) == .black)
    #expect(firstFillColor(store) == .red)
    #expect(firstFillColor(store) == .red)
}

@Test func aFreshStoreIsAFreshScopeNotAGlobalLeak() {
    let store = StateStore()
    _ = firstFillColor(store)
    #expect(firstFillColor(store) == .red)

    let otherStore = StateStore()
    #expect(firstFillColor(otherStore) == .black, "a new store should see the entrance again, not the other store's state")
}
