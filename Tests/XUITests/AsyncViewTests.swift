import Testing
@testable import XUI

private func labels(for view: some XView, store: StateStore) -> [String] {
    let canvas = RecordingCanvas()
    LayoutHost(canvas: Size(width: 200, height: 100)).render(view, into: canvas, store: store)
    return canvas.labels.map(\.string)
}

@Test func asyncViewRendersPlaceholderThenSuccess() async {
    let store = StateStore()
    let view = AsyncView(
        operation: { 42 },
        content: { Text("value:\($0)") },
        placeholder: { Text("loading") },
        failure: { Text("error:\($0)") }
    )

    #expect(labels(for: view, store: store) == ["loading"])

    for _ in 0..<10 {
        await Task.yield()
        if labels(for: view, store: store) == ["value:42"] { return }
    }

    Issue.record("async view did not publish its result")
}

@Test func asyncViewRendersFailureMessage() async {
    let store = StateStore()
    let view = AsyncView(
        operation: { throw TestAsyncError.failed },
        content: { Text("value:\($0)") },
        placeholder: { Text("loading") },
        failure: { Text("error:\($0)") }
    )

    #expect(labels(for: view, store: store) == ["loading"])

    for _ in 0..<10 {
        await Task.yield()
        if labels(for: view, store: store) == ["error:failed"] { return }
    }

    Issue.record("async view did not publish its failure")
}

private enum TestAsyncError: Error, CustomStringConvertible {
    case failed
    var description: String { "failed" }
}
