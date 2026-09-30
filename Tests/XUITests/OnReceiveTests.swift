import Testing
@testable import XUI

/// Proves `.onReceive` subscribes exactly once across separate `lower`
/// passes over a freshly-rebuilt value-type tree (same identity-keyed
/// persistence `@XState` relies on), and that a node dropped from the tree
/// stops receiving once `StateStore` garbage-collects its box — mirroring
/// `StatefulXViewTests`'s coverage of `@XState` itself.

@XUIActor
private func resolve(_ signal: Signal<Int>, log: @escaping (Int) -> Void, store: StateStore) async {
    let view = Color(.black).onReceive(signal, perform: log)
    _ = await LayoutHost(canvas: Size(width: 10, height: 10)).resolveAnchors(view, store: store)
}

@Test @XUIActor func onReceiveSubscribesOnceAcrossRepeatedWalks() async {
    let signal = Signal<Int>()
    var received: [Int] = []
    let store = StateStore()

    await resolve(signal, log: { received.append($0) }, store: store)
    await resolve(signal, log: { received.append($0) }, store: store)

    signal.send(1)

    #expect(received == [1], "a second walk should reuse the existing subscription, not add a second one")
}

@Test @XUIActor func onReceiveUnsubscribesOnceTheNodeStopsBeingDeclared() async {
    let signal = Signal<Int>()
    var received: [Int] = []
    let store = StateStore()

    await resolve(signal, log: { received.append($0) }, store: store)

    // A pass that never re-declares the `.onReceive` node at all — its box
    // goes unvisited and `endPass()` drops it.
    store.beginPass()
    store.endPass()

    signal.send(1)

    #expect(received.isEmpty, "the dropped node's subscription should have been cancelled")
}
