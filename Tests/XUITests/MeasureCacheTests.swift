import Testing
@testable import XUI

/// Counts how often a `Text` is measured while a stack tree is laid out.
private final class MeasureCount: @unchecked Sendable { var calls = 0 }

private struct Nest: XView {
    var level: Int
    @XViewBuilder var body: some XView {
        if level == 0 {
            Text("leaf", size: 10)
        } else {
            VStack(spacing: 2) {
                HStack { Nest(level: level - 1); Spacer() }
                Spacer()
            }
        }
    }
}

@XUIActor
private func textMeasurements(nestedStacks depth: Int) async -> Int {
    let counter = MeasureCount()
    var environment = EnvironmentValues()
    environment.measureText = { string, size, _ in
        counter.calls += 1
        return Size(width: Double(string.count) * size, height: size)
    }

    // The same leaf, wrapped `depth` times in a stack that also holds a Spacer:
    // every level asks its child for a size several times.
    let view = Nest(level: depth)
    await LayoutHost(canvas: Size(width: 400, height: 400), environment: environment)
        .resolveAnchors(view, store: StateStore())
    return counter.calls
}

@Test @XUIActor func measuringANestedStackDoesNotMultiplyWithDepth() async {
    // Without remembering sizes the count grows about threefold per level
    // (thousands of measurements at depth 8); with it, it grows by a small
    // constant per level.
    let shallow = await textMeasurements(nestedStacks: 2)
    let deep = await textMeasurements(nestedStacks: 8)
    #expect(deep < 200, "deep tree measured its text \(deep) times")
    #expect(deep <= shallow + 6 * 12, "shallow \(shallow) vs deep \(deep): should grow linearly")
}

@Test @XUIActor func aNodeRemembersASizeOnlyWithinOnePass() async {
    let counter = MeasureCount()
    var environment = EnvironmentValues()
    environment.measureText = { string, size, _ in
        counter.calls += 1
        return Size(width: Double(string.count) * size, height: size)
    }
    let view = VStack { Text("a", size: 10) }
    let host = LayoutHost(canvas: Size(width: 100, height: 100), environment: environment)
    _ = await host.resolveAnchors(view, store: StateStore())
    let first = counter.calls
    _ = await host.resolveAnchors(view, store: StateStore())
    #expect(counter.calls == first * 2, "each pass measures for itself")
}
