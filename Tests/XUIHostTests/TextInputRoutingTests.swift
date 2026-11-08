import Foundation
import Testing
import XRender
import XUI
@testable import XUIHost

private final class Field: @unchecked Sendable {
    var text = ""
    var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
}

@XUIActor
private func hostWithField(_ field: Field, other: Field? = nil) async -> (XUIHost, XUIFrame) {
    let host = XUIHost(size: RenderSize(width: 300, height: 200))
    func tree() -> some XView {
        VStack(spacing: 20) {
            TextField("one", text: field.binding, id: "one")
            TextField("two", text: (other ?? field).binding, id: "two")
        }
    }
    let frame = await host.render(tree(), time: 0)
    return (host, frame)
}

private func tapPoint(_ frame: XUIFrame, _ id: String) -> RenderPoint {
    let g = frame.layout.tapGestures.first { $0.id == id }!
    return RenderPoint(x: Float(g.rect.midX), y: Float(g.rect.midY))
}

@Test @XUIActor
func keysGoNowhereUntilAFieldIsFocused() async {
    let field = Field()
    let (host, _) = await hostWithField(field)
    #expect(!host.key(KeyEvent(.character("a"))))
    #expect(field.text.isEmpty)
}

@Test @XUIActor
func pressingAFieldFocusesItAndTypingEdits() async {
    let field = Field()
    let (host, frame) = await hostWithField(field)
    let p = tapPoint(frame, "one")
    _ = host.pointer(PointerEvent(phase: .began, position: p), in: frame)
    _ = host.pointer(PointerEvent(phase: .ended, position: p), in: frame)
    #expect(host.textFocus.focusedID == "one")
    #expect(host.key(KeyEvent(.character("h"))))
    #expect(host.key(KeyEvent(.character("i"))))
    #expect(field.text == "hi")
    #expect(host.key(KeyEvent(.backspace)))
    #expect(field.text == "h")
}

@Test @XUIActor
func pressingOutsideDismissesTheKeyboard() async {
    let field = Field()
    let (host, frame) = await hostWithField(field)
    let p = tapPoint(frame, "one")
    _ = host.pointer(PointerEvent(phase: .began, position: p), in: frame)
    _ = host.pointer(PointerEvent(phase: .ended, position: p), in: frame)
    #expect(host.textFocus.focusedID == "one")
    let away = RenderPoint(x: 290, y: 190)
    _ = host.pointer(PointerEvent(phase: .began, position: away), in: frame)
    #expect(host.textFocus.focusedID == nil)
}

@Test @XUIActor
func tabMovesBetweenFieldsAndShiftTabGoesBack() async {
    let a = Field(), b = Field()
    let (host, frame) = await hostWithField(a, other: b)
    let p = tapPoint(frame, "one")
    _ = host.pointer(PointerEvent(phase: .began, position: p), in: frame)
    _ = host.pointer(PointerEvent(phase: .ended, position: p), in: frame)
    #expect(host.key(KeyEvent(.tab)))
    #expect(host.textFocus.focusedID == "two")
    _ = host.key(KeyEvent(.character("z")))
    #expect(b.text == "z" && a.text.isEmpty)
    #expect(host.key(KeyEvent(.tab, modifiers: .shift)))
    #expect(host.textFocus.focusedID == "one")
}

@Test @XUIActor
func commandShortcutsPassThroughButSelectAllAndClipboardWork() async {
    let field = Field()
    let (host, frame) = await hostWithField(field)
    let p = tapPoint(frame, "one")
    _ = host.pointer(PointerEvent(phase: .began, position: p), in: frame)
    _ = host.pointer(PointerEvent(phase: .ended, position: p), in: frame)
    #expect(!host.key(KeyEvent(.character("q"), modifiers: .command)))   // app shortcut, not text
    #expect(field.text.isEmpty)

    _ = host.key(KeyEvent(.character("a")))
    _ = host.key(KeyEvent(.character("b")))
    _ = await host.render(VStack(spacing: 20) {
        TextField("one", text: field.binding, id: "one")
        TextField("two", text: field.binding, id: "two")
    }, time: 1)
    _ = host.key(KeyEvent(.character("a"), modifiers: .command))
    _ = host.key(KeyEvent(.character("x"), modifiers: .command))
    #expect(host.clipboard.string == "ab")
    #expect(field.text.isEmpty)
    _ = host.key(KeyEvent(.character("v"), modifiers: .command))
    #expect(field.text == "ab")
}

@Test
func keyMapFollowsMacConventions() {
    func input(_ key: KeyEvent.Key, _ m: KeyModifiers = []) -> TextInputEvent? {
        if case .input(let e)? = TextKeyMap.command(for: KeyEvent(key, modifiers: m)) { return e }
        return nil
    }
    #expect(input(.left, .option) == .move(.wordLeft, extend: false))
    #expect(input(.right, [.command, .shift]) == .move(.lineEnd, extend: true))
    #expect(input(.backspace, .option) == .deleteWordBackward)
    #expect(input(.backspace, .command) == .deleteToLineStart)
    #expect(input(.returnKey) == .submit)
    #expect(input(.escape) == .cancel)
    #expect(input(.character("A")) == .insert("A"))
    #expect(input(.character("k"), .command) == nil)
    #expect(input(.character("a"), .control) == .move(.lineStart, extend: false))
}
