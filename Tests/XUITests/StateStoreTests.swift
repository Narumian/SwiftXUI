import Testing
@testable import XUI

@Test func sameIdentityReturnsTheSameBox() {
    let store = StateStore()
    let id = StateIdentity.root.child(type: Int.self, index: 0)
    let a: StateStore.Box<Int> = store.box(for: id) { 1 }
    let b: StateStore.Box<Int> = store.box(for: id) { 99 }
    #expect(a === b)
    #expect(b.value == 1)
}

@Test func endPassPurgesIdentitiesNotReVisited() {
    let store = StateStore()
    let id = StateIdentity.root.child(type: Int.self, index: 0)

    store.beginPass()
    let first: StateStore.Box<Int> = store.box(for: id) { 7 }
    first.value = 42
    store.endPass()

    // A second pass that never revisits `id` should drop its box.
    store.beginPass()
    store.endPass()

    let second: StateStore.Box<Int> = store.box(for: id) { 7 }
    #expect(second.value == 7, "expected a fresh box after the id went unvisited for a full pass")
}

@Test func revisitingWithinAPassKeepsTheBoxAlive() {
    let store = StateStore()
    let id = StateIdentity.root.child(type: Int.self, index: 0)

    store.beginPass()
    let first: StateStore.Box<Int> = store.box(for: id) { 7 }
    first.value = 42
    let second: StateStore.Box<Int> = store.box(for: id) { 7 }
    store.endPass()

    #expect(first === second)
    #expect(second.value == 42)
}

@Test func onRemoveFiresOnceWithTheLastValueWhenAnIdentityGoesUnvisited() {
    let store = StateStore()
    let id = StateIdentity.root.child(type: Int.self, index: 0)

    store.beginPass()
    let box: StateStore.Box<Int> = store.box(for: id) { 7 }
    box.value = 42
    var removed: [Int] = []
    box.onRemove = { removed.append($0) }
    store.endPass()

    #expect(removed.isEmpty, "still revisited this pass — must not fire yet")

    store.beginPass()
    store.endPass()

    #expect(removed == [42], "dropped after a full pass without a revisit — fires once, with the last value")

    store.beginPass()
    store.endPass()

    #expect(removed == [42], "must not fire again on a later pass")
}

@Test func onRemoveDoesNotFireWhileTheIdentityKeepsBeingRevisited() {
    let store = StateStore()
    let id = StateIdentity.root.child(type: Int.self, index: 0)

    var removed: [Int] = []
    for _ in 0..<3 {
        store.beginPass()
        let box: StateStore.Box<Int> = store.box(for: id) { 7 }
        box.onRemove = { removed.append($0) }
        store.endPass()
    }

    #expect(removed.isEmpty)
}
