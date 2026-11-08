import Foundation
import Testing
import XRender
import XUI
@testable import XUIHost

private final class Field: @unchecked Sendable {
    var text = ""
    var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
}

private let screen = RenderSize(width: 800, height: 600)

@XUIActor
private func app(_ field: Field, kind: TextInputKind = .text, host: XUIHost, time: Double) async -> XUIFrame {
    await host.render(
        TextInputArea {
            VStack(spacing: 12) {
                TextField("Name", text: field.binding, id: "name", kind: kind)
                Spacer()
            }
            .padding(16)
        },
        time: time
    )
}

/// Renders enough frames for the keyboard to finish sliding in.
@XUIActor
private func settle(_ field: Field, kind: TextInputKind = .text, host: XUIHost, from start: Double = 0) async -> (XUIFrame, Double) {
    var t = start
    var frame = await app(field, kind: kind, host: host, time: t)
    for _ in 0..<20 {
        t += 0.02
        frame = await app(field, kind: kind, host: host, time: t)
    }
    return (frame, t)
}

@XUIActor
private func focusField(_ host: XUIHost, _ frame: XUIFrame) {
    let g = frame.layout.tapGestures.first { $0.id == "name" }!
    let p = RenderPoint(x: Float(g.rect.midX), y: Float(g.rect.midY))
    _ = host.pointer(PointerEvent(phase: .began, position: p), in: frame)
    _ = host.pointer(PointerEvent(phase: .ended, position: p), in: frame)
}

@XUIActor
private func tap(_ host: XUIHost, _ frame: XUIFrame, at point: Point, id: Int = 0) {
    let p = RenderPoint(x: Float(point.x), y: Float(point.y))
    _ = host.pointer(PointerEvent(id: id, phase: .began, position: p), in: frame)
    _ = host.pointer(PointerEvent(id: id, phase: .ended, position: p), in: frame)
}

@Test @XUIActor
func theKeyboardAppearsWhenAFieldIsFocusedAndLeavesWhenItIsDismissed() async {
    let field = Field()
    let host = XUIHost(size: screen)
    var (frame, t) = await settle(field, host: host)
    #expect(host.textFocus.focusedID == nil)
    focusField(host, frame)
    #expect(host.textFocus.focusedID == "name")
    (frame, t) = await settle(field, host: host, from: t)
    #expect(host.textFocus.wantsKeyboard)
    // The keyboard registered itself for pointer handling.
    let probe = PointerInput(id: 9, phase: .began, position: Point(x: 400, y: 590))
    #expect(host.textFocus.handleKeyboardPointer(probe))
    _ = host.textFocus.handleKeyboardPointer(PointerInput(id: 9, phase: .cancelled, position: Point(x: 400, y: 590)))

    // Press on the empty content area above the keyboard: dismisses.
    _ = host.pointer(PointerEvent(phase: .began, position: RenderPoint(x: 400, y: 200)), in: frame)
    #expect(host.textFocus.focusedID == nil)
}

@Test @XUIActor
func typingOnTheKeyboardEditsTheField() async {
    let field = Field()
    let host = XUIHost(size: screen)
    var (frame, t) = await settle(field, host: host)
    focusField(host, frame)
    (frame, t) = await settle(field, host: host, from: t)

    let metrics = KeyboardMetrics.compute(container: Size(width: 800, height: 600), rowCount: 4)
    let rows = KeyboardLayout.rows(page: .letters, shift: .off, returnKey: .done)
    let placed = metrics.place(rows, in: metrics.rect)
    func centre(_ label: String) -> Point {
        let k = placed.first { $0.key.label == label }!
        return Point(x: k.rect.midX, y: k.rect.midY)
    }
    tap(host, frame, at: centre("h"))
    tap(host, frame, at: centre("i"))
    #expect(field.text == "hi")
    tap(host, frame, at: centre("⌫"))
    #expect(field.text == "h")
}

@Test @XUIActor
func shiftCapitalisesOneLetterThenReleases() async {
    let field = Field()
    let host = XUIHost(size: screen)
    var (frame, t) = await settle(field, host: host)
    focusField(host, frame)
    (frame, t) = await settle(field, host: host, from: t)
    let metrics = KeyboardMetrics.compute(container: Size(width: 800, height: 600), rowCount: 4)
    func centre(_ shift: ShiftState, _ label: String) -> Point {
        let rows = KeyboardLayout.rows(page: .letters, shift: shift, returnKey: .done)
        let k = metrics.place(rows, in: metrics.rect).first { $0.key.label == label }!
        return Point(x: k.rect.midX, y: k.rect.midY)
    }
    tap(host, frame, at: centre(.off, "⇧"))
    // The keyboard repaints with capitals before the next key.
    (frame, t) = await settle(field, host: host, from: t)
    tap(host, frame, at: centre(.once, "A"))
    (frame, t) = await settle(field, host: host, from: t)
    tap(host, frame, at: centre(.off, "a"))
    #expect(field.text == "Aa")
}

@Test @XUIActor
func twoFingersTypeAtTheSameTime() async {
    let field = Field()
    let host = XUIHost(size: screen)
    var (frame, t) = await settle(field, host: host)
    focusField(host, frame)
    (frame, t) = await settle(field, host: host, from: t)
    let metrics = KeyboardMetrics.compute(container: Size(width: 800, height: 600), rowCount: 4)
    let placed = metrics.place(KeyboardLayout.rows(page: .letters, shift: .off, returnKey: .done), in: metrics.rect)
    func rp(_ label: String) -> RenderPoint {
        let k = placed.first { $0.key.label == label }!
        return RenderPoint(x: Float(k.rect.midX), y: Float(k.rect.midY))
    }
    // Left thumb down on "a", right thumb down on "l", then both lift.
    _ = host.pointer(PointerEvent(id: 1, phase: .began, position: rp("a")), in: frame)
    _ = host.pointer(PointerEvent(id: 2, phase: .began, position: rp("l")), in: frame)
    _ = host.pointer(PointerEvent(id: 1, phase: .ended, position: rp("a")), in: frame)
    _ = host.pointer(PointerEvent(id: 2, phase: .ended, position: rp("l")), in: frame)
    #expect(field.text == "al")
}

@Test @XUIActor
func holdingBackspaceRepeatsAfterADelay() async {
    let field = Field()
    field.text = "abcdefghij"
    let host = XUIHost(size: screen)
    var (frame, t) = await settle(field, host: host)
    focusField(host, frame)
    (frame, t) = await settle(field, host: host, from: t)
    let metrics = KeyboardMetrics.compute(container: Size(width: 800, height: 600), rowCount: 4)
    let k = metrics.place(KeyboardLayout.rows(page: .letters, shift: .off, returnKey: .done), in: metrics.rect).first { $0.key.label == "⌫" }!
    let p = RenderPoint(x: Float(k.rect.midX), y: Float(k.rect.midY))
    _ = host.pointer(PointerEvent(id: 1, phase: .began, position: p), in: frame)
    #expect(field.text.count == 9)             // fired on touch-down
    for _ in 0..<10 { t += 0.02; frame = await app(field, host: host, time: t) }
    #expect(field.text.count == 9)             // still inside the initial delay
    for _ in 0..<40 { t += 0.02; frame = await app(field, host: host, time: t) }
    #expect(field.text.count < 9)              // repeating now
    let during = field.text.count
    _ = host.pointer(PointerEvent(id: 1, phase: .ended, position: p), in: frame)
    #expect(field.text.count == during)        // lifting does not delete once more
    for _ in 0..<20 { t += 0.02; frame = await app(field, host: host, time: t) }
    #expect(field.text.count == during)
}

@Test @XUIActor
func theNumberPadHasDigitsAndNoLetters() async {
    let field = Field()
    let host = XUIHost(size: screen)
    var (frame, t) = await settle(field, kind: .number, host: host)
    focusField(host, frame)
    (frame, t) = await settle(field, kind: .number, host: host, from: t)
    let metrics = KeyboardMetrics.compute(container: Size(width: 800, height: 600), rowCount: 4, numberPad: true)
    let placed = metrics.place(KeyboardLayout.rows(page: .numberPad, shift: .off, returnKey: .done), in: metrics.rect)
    for label in ["4", "2", "."] {
        let k = placed.first { $0.key.label == label }!
        tap(host, frame, at: Point(x: k.rect.midX, y: k.rect.midY))
    }
    #expect(field.text == "42.")
}
