import Testing
@testable import XUI

private final class Model: @unchecked Sendable {
    var text: String
    init(_ text: String = "") { self.text = text }
    var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
}

private let fieldCanvas = Size(width: 220, height: 80)

/// With the default measurer a character is 0.6 em wide: 10.2 pt at 17 pt.
private let glyph = 17 * 0.6
private let padding = TextFieldStyle().horizontalPadding

@XUIActor
private func renderField(
    _ model: Model, focus: TextFocusStore, state: StateStore, time: Double = 0, placeholder: String = "Search"
) async -> (RecordingCanvas, RenderResult) {
    let view = TextField(placeholder, text: model.binding, id: "field")
        .environment(focus)
    var environment = EnvironmentValues()
    environment.fxTime = time
    let surface = RecordingCanvas()
    let result = await LayoutHost(canvas: fieldCanvas, environment: environment).render(view, into: surface, store: state)
    return (surface, result)
}

@XUIActor
private func press(_ result: RenderResult, runtime: inout GestureRuntime, x: Double, y: Double = 20, time: Double = 1) {
    _ = runtime.handle(PointerInput(id: 1, phase: .began, position: Point(x: x, y: y), timestamp: time), in: result)
}

@XUIActor
private func release(_ result: RenderResult, runtime: inout GestureRuntime, x: Double, y: Double = 20, time: Double = 1) {
    _ = runtime.handle(PointerInput(id: 1, phase: .ended, position: Point(x: x, y: y), timestamp: time), in: result)
}

@Test @XUIActor
func anUnfocusedFieldShowsItsPlaceholderAndNoCaret() async {
    let (surface, _) = await renderField(Model(), focus: TextFocusStore(), state: StateStore())
    #expect(surface.labels.map(\.string) == ["Search"])
    #expect(surface.fills.filter { $0.rect.width == 2 }.isEmpty)
}

@Test @XUIActor
func aTapFocusesTheFieldAndTheCaretAppears() async {
    let focus = TextFocusStore()
    let state = StateStore()
    let (_, first) = await renderField(Model("hi"), focus: focus, state: state)
    var runtime = GestureRuntime()
    press(first, runtime: &runtime, x: 100)
    release(first, runtime: &runtime, x: 100)
    #expect(focus.focusedID == "field")

    let (surface, _) = await renderField(Model("hi"), focus: focus, state: state)
    #expect(surface.fills.contains { $0.rect.width == 2 })   // the caret
}

@Test @XUIActor
func typingReachesTheBindingThroughTheFocusStore() async {
    let focus = TextFocusStore()
    let model = Model()
    let state = StateStore()
    _ = await renderField(model, focus: focus, state: state)
    focus.focus("field")
    #expect(focus.send(.insert("a")))
    #expect(focus.send(.insert("b")))
    #expect(model.text == "ab")
    #expect(focus.send(.deleteBackward))
    #expect(model.text == "a")

    let (surface, _) = await renderField(model, focus: focus, state: state)
    #expect(surface.labels.map(\.string) == ["a"])
}

@Test @XUIActor
func eventsGoNowhereWithoutAFocusedField() async {
    let focus = TextFocusStore()
    let model = Model()
    _ = await renderField(model, focus: focus, state: StateStore())
    #expect(!focus.send(.insert("x")))
    #expect(model.text.isEmpty)
}

@Test @XUIActor
func pressingBetweenGlyphsPlacesTheCaretThere() async {
    let focus = TextFocusStore()
    let model = Model("abcd")
    let state = StateStore()
    let (_, first) = await renderField(model, focus: focus, state: state)
    var runtime = GestureRuntime()
    // Just past the middle of the second glyph → caret after "ab".
    let x = padding + glyph * 2 + 2
    press(first, runtime: &runtime, x: x)
    release(first, runtime: &runtime, x: x)
    _ = await renderField(model, focus: focus, state: state)
    _ = focus.send(.insert("X"))
    #expect(model.text == "abXcd")
}

@Test @XUIActor
func pressingPastTheEndPutsTheCaretAtTheEnd() async {
    let focus = TextFocusStore()
    let model = Model("abc")
    let state = StateStore()
    let (_, first) = await renderField(model, focus: focus, state: state)
    var runtime = GestureRuntime()
    press(first, runtime: &runtime, x: 210)
    release(first, runtime: &runtime, x: 210)
    _ = await renderField(model, focus: focus, state: state)
    _ = focus.send(.insert("!"))
    #expect(model.text == "abc!")
}

@Test @XUIActor
func draggingSelectsAndTypingReplacesTheSelection() async {
    let focus = TextFocusStore()
    let model = Model("abcdef")
    let state = StateStore()
    let (_, first) = await renderField(model, focus: focus, state: state)
    var runtime = GestureRuntime()
    press(first, runtime: &runtime, x: padding + glyph * 1)
    _ = runtime.handle(PointerInput(id: 1, phase: .moved, position: Point(x: padding + glyph * 4, y: 20)), in: first)
    // The drag callback maps against the metrics of the last drawn frame.
    _ = await renderField(model, focus: focus, state: state)
    _ = runtime.handle(PointerInput(id: 1, phase: .moved, position: Point(x: padding + glyph * 4, y: 20)), in: first)
    release(first, runtime: &runtime, x: padding + glyph * 4)
    let (surface, _) = await renderField(model, focus: focus, state: state)
    #expect(surface.fills.contains { $0.color == TextFieldStyle().colors(.standard).selection })
    _ = focus.send(.insert("-"))
    #expect(model.text == "a-ef")
}

@Test @XUIActor
func aLongTextScrollsToKeepTheCaretVisible() async {
    let focus = TextFocusStore()
    let model = Model(String(repeating: "m", count: 60))
    let state = StateStore()
    _ = await renderField(model, focus: focus, state: state)
    focus.focus("field")
    _ = focus.send(.move(.lineEnd, extend: false))
    let (surface, _) = await renderField(model, focus: focus, state: state)
    let caret = surface.fills.first { $0.rect.width == 2 }
    #expect(caret != nil)
    #expect((caret?.rect.maxX ?? 0) <= fieldCanvas.width - padding + 1)
    #expect((caret?.rect.x ?? 0) >= padding)
    // And back to the start returns the text to its origin.
    _ = focus.send(.move(.lineStart, extend: false))
    let (home, _) = await renderField(model, focus: focus, state: state)
    #expect(home.labels.first?.rect.x == padding)
}

@Test @XUIActor
func submitRunsTheHandlerAndEscapeDropsFocus() async {
    let focus = TextFocusStore()
    let log = LogBox<String>()
    let view = TextField("", text: Model().binding, id: "field", onSubmit: { log.append("submit") })
        .environment(focus)
    let surface = RecordingCanvas()
    _ = await LayoutHost(canvas: fieldCanvas).render(view, into: surface, store: StateStore())
    focus.focus("field")
    _ = focus.send(.submit)
    #expect(log.values == ["submit"])
    _ = focus.send(.cancel)
    #expect(focus.focusedID == nil)
}

@Test
func tabMovesFocusInReadingOrderAndWraps() {
    let store = TextFocusStore()
    store.hostManagesFrames = true
    store.beginFrame()
    for (id, y) in [("b", 60.0), ("a", 10.0), ("c", 110.0)] {
        store.record(id: id, rect: Rect(x: 0, y: y, width: 100, height: 30), kind: .text, returnKey: .done) { _ in }
    }
    store.endFrame()
    store.focusNext()
    #expect(store.focusedID == "a")
    store.focusNext()
    #expect(store.focusedID == "b")
    store.focusNext()
    store.focusNext()
    #expect(store.focusedID == "a")
    store.focusNext(reverse: true)
    #expect(store.focusedID == "c")
}

@Test
func aFocusedFieldThatStopsBeingDrawnLosesFocus() {
    let store = TextFocusStore()
    store.hostManagesFrames = true
    store.beginFrame()
    store.record(id: "f", rect: Rect(x: 0, y: 0, width: 10, height: 10), kind: .text, returnKey: .done) { _ in }
    store.endFrame()
    store.focus("f")
    store.beginFrame()
    store.endFrame()
    #expect(store.focusedID == nil)
}

@Test
func pressingOutsideDismissesButInsideAFieldOrTheKeyboardKeepsFocus() {
    let store = TextFocusStore()
    store.hostManagesFrames = true
    store.beginFrame()
    store.record(id: "f", rect: Rect(x: 0, y: 0, width: 100, height: 30), kind: .text, returnKey: .done) { _ in }
    store.recordKeepFocus(Rect(x: 0, y: 200, width: 300, height: 100))
    store.endFrame()
    store.focus("f")
    #expect(!store.blurIfOutside(Point(x: 10, y: 10)))
    #expect(!store.blurIfOutside(Point(x: 50, y: 250)))
    #expect(store.focusedID == "f")
    #expect(store.blurIfOutside(Point(x: 500, y: 500)))
    #expect(store.focusedID == nil)
}

@Test
func metricsFindTheNearestCaretOffset() {
    let metrics = TextMetrics(
        text: TextEditing(text: "abcd"), fontSize: 10, font: .ui,
        measure: { s, size, _ in Size(width: Double(s.count) * size * 0.6, height: size * 1.3) }
    )
    #expect(metrics.offset(at: -5) == 0)
    #expect(metrics.offset(at: 2.9) == 0)
    #expect(metrics.offset(at: 3.1) == 1)
    #expect(metrics.offset(at: 100) == 4)
    #expect(metrics.x(of: 3) == 18)
}

@Test
func scrollKeepsTheCaretInViewAndNeverOverscrolls() {
    // Caret beyond the right edge scrolls just enough (plus a lead).
    let right = TextMetrics.scroll(current: 0, caretX: 300, textWidth: 300, visibleWidth: 100, caretWidth: 2)
    #expect(300 - right <= 100)
    #expect(right <= 300 + 2 - 100)
    // Deleting text pulls the scroll back so no blank space remains.
    #expect(TextMetrics.scroll(current: 200, caretX: 50, textWidth: 60, visibleWidth: 100, caretWidth: 2) == 0)
}
