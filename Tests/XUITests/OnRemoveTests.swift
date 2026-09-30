import Testing
@testable import XUI

/// `.onRemove` keeps a node's latest declared value on a `Box` every walk,
/// and fires once with the last one the walk after this node stops being
/// declared at all — same identity-keyed persistence `@XState`/`.onReceive`
/// rely on, but refreshed each walk instead of installed once (see
/// `Reactive/OnRemove.swift`'s doc comment for why).

private func resolve(_ view: some XView, store: StateStore) {
    _ = LayoutHost(canvas: Size(width: 10, height: 10)).resolveAnchors(view, store: store)
}

@Test func onRemoveFiresWithTheLastDeclaredValueOnceTheNodeStopsBeingDeclared() {
    let store = StateStore()
    var removed: [Int] = []

    resolve(Color(.black).onRemove(1, perform: { removed.append($0) }), store: store)
    resolve(Color(.black).onRemove(2, perform: { removed.append($0) }), store: store)
    #expect(removed.isEmpty, "still declared — must not fire yet")

    // A pass that never redeclares the `.onRemove` node at all.
    store.beginPass()
    store.endPass()

    #expect(removed == [2], "fires once with the LAST declared value, not the first")
}

@Test func onRemoveDoesNotFireWhileRedeclaredEveryWalk() {
    let store = StateStore()
    var removed: [Int] = []
    for _ in 0..<3 {
        resolve(Color(.black).onRemove(9, perform: { removed.append($0) }), store: store)
    }
    #expect(removed.isEmpty)
}

@Test func onRemoveWithNoValueFiresOnceOnDisappearance() {
    let store = StateStore()
    var count = 0
    resolve(Color(.black).onRemove(perform: { count += 1 }), store: store)

    store.beginPass()
    store.endPass()

    #expect(count == 1)

    store.beginPass()
    store.endPass()

    #expect(count == 1, "must not fire again on a later pass")
}

@Test func fxOnRemoveFiresWithTheLastDeclaredValueOnceNoLongerEmitted() {
    let store = StateStore()
    var removed: [Int] = []

    func resolveOnce(_ fx: some FX) {
        store.beginPass()
        var out: [any FX] = []
        emit(fx, id: .root, store: store, into: &out)
        store.endPass()
    }

    resolveOnce(EmptyFX().onRemove(1, perform: { removed.append($0) }))
    resolveOnce(EmptyFX().onRemove(2, perform: { removed.append($0) }))
    #expect(removed.isEmpty)

    store.beginPass()
    store.endPass()

    #expect(removed == [2])
}
