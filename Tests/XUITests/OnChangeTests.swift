import Testing
@testable import XUI

/// `.onChange` diffs a declared value against what this node declared last
/// walk, firing `(old, new)` whenever it differs — `old` is `nil` on the
/// first declaration, and nothing fires while the same value keeps being
/// redeclared.

@XUIActor
private func resolve(_ view: some XView, store: StateStore) async {
    _ = await LayoutHost(canvas: Size(width: 10, height: 10)).resolveAnchors(view, store: store)
}

@Test @XUIActor func onChangeFiresOnTheFirstDeclarationWithNilOld() async {
    let store = StateStore()
    var seen: [(Int?, Int)] = []
    await resolve(Color(.black).onChange(of: 1) { old, new in seen.append((old, new)) }, store: store)

    #expect(seen.count == 1)
    #expect(seen[0].0 == nil)
    #expect(seen[0].1 == 1)
}

@Test @XUIActor func onChangeDoesNotFireWhileRedeclaringTheSameValue() async {
    let store = StateStore()
    var seen: [(Int?, Int)] = []
    for _ in 0..<3 {
        await resolve(Color(.black).onChange(of: 1) { old, new in seen.append((old, new)) }, store: store)
    }
    #expect(seen.count == 1, "only the first declaration should fire")
}

@Test @XUIActor func onChangeFiresWithOldAndNewWhenTheValueDiffers() async {
    let store = StateStore()
    var seen: [(Int?, Int)] = []
    await resolve(Color(.black).onChange(of: 1) { old, new in seen.append((old, new)) }, store: store)
    await resolve(Color(.black).onChange(of: 2) { old, new in seen.append((old, new)) }, store: store)

    #expect(seen.count == 2)
    #expect(seen[1].0 == 1)
    #expect(seen[1].1 == 2)
}
