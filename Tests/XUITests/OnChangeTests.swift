import Testing
@testable import XUI

/// `.onChange` diffs a declared value against what this node declared last
/// walk, firing `(old, new)` whenever it differs — `old` is `nil` on the
/// first declaration, and nothing fires while the same value keeps being
/// redeclared.

private func resolve(_ view: some XView, store: StateStore) {
    _ = LayoutHost(canvas: Size(width: 10, height: 10)).resolveAnchors(view, store: store)
}

@Test func onChangeFiresOnTheFirstDeclarationWithNilOld() {
    let store = StateStore()
    var seen: [(Int?, Int)] = []
    resolve(Color(.black).onChange(of: 1) { old, new in seen.append((old, new)) }, store: store)

    #expect(seen.count == 1)
    #expect(seen[0].0 == nil)
    #expect(seen[0].1 == 1)
}

@Test func onChangeDoesNotFireWhileRedeclaringTheSameValue() {
    let store = StateStore()
    var seen: [(Int?, Int)] = []
    for _ in 0..<3 {
        resolve(Color(.black).onChange(of: 1) { old, new in seen.append((old, new)) }, store: store)
    }
    #expect(seen.count == 1, "only the first declaration should fire")
}

@Test func onChangeFiresWithOldAndNewWhenTheValueDiffers() {
    let store = StateStore()
    var seen: [(Int?, Int)] = []
    resolve(Color(.black).onChange(of: 1) { old, new in seen.append((old, new)) }, store: store)
    resolve(Color(.black).onChange(of: 2) { old, new in seen.append((old, new)) }, store: store)

    #expect(seen.count == 2)
    #expect(seen[1].0 == 1)
    #expect(seen[1].1 == 2)
}
