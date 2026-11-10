import Foundation
import Testing
import XRender
import XUI
@testable import XUIHost

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

private final class Text: @unchecked Sendable {
    var text = ""
    var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
}

@XUIActor
private func render(_ host: XUIHost, enabled: Bool = true, counter: Counter, field: Text? = nil) async -> XUIFrame {
    let action: @Sendable () -> Void = { counter.add("undo") }
    return await host.render(
        VStack(spacing: 10) {
            Color(red: 0.2, green: 0.2, blue: 0.2).frame(width: 40, height: 40)
                .keyboardShortcut("z", modifiers: .command, isEnabled: enabled, action: action)
                .keyboardShortcut("y", modifiers: .command, isEnabled: enabled) { counter.add("redo") }
            if let field { TextField("t", text: field.binding, id: "t") }
        }, time: 0)
}

@Test @XUIActor
func aDeclaredShortcutRunsAndIsTaken() async {
    let counter = Counter()
    let host = XUIHost(size: RenderSize(width: 200, height: 200))
    _ = await render(host, counter: counter)
    #expect(host.shortcuts.matches(KeyEvent(.character("z"), modifiers: .command)))
    #expect(host.consumes(KeyEvent(.character("Z"), modifiers: .command)))
    #expect(host.key(KeyEvent(.character("z"), modifiers: .command)))
    #expect(host.key(KeyEvent(.character("y"), modifiers: .command)))
    #expect(counter.all == ["undo", "redo"])
}

@Test @XUIActor
func otherKeysAreLeftToTheSystem() async {
    let counter = Counter()
    let host = XUIHost(size: RenderSize(width: 200, height: 200))
    _ = await render(host, counter: counter)
    for event in [KeyEvent(.character("q"), modifiers: .command), KeyEvent(.character("z")),
                  KeyEvent(.character("z"), modifiers: [.command, .shift]), KeyEvent(.returnKey)] {
        #expect(!host.consumes(event))
        #expect(!host.key(event))
    }
    #expect(counter.all.isEmpty)
}

@Test @XUIActor
func aDisabledViewDoesNotTakeItsKey() async {
    let counter = Counter()
    let host = XUIHost(size: RenderSize(width: 200, height: 200))
    _ = await render(host, enabled: false, counter: counter)
    #expect(!host.consumes(KeyEvent(.character("z"), modifiers: .command)))
    #expect(!host.key(KeyEvent(.character("z"), modifiers: .command)))
    #expect(counter.all.isEmpty)
}

@Test @XUIActor
func theNextFrameReplacesTheShortcuts() async {
    let counter = Counter()
    let host = XUIHost(size: RenderSize(width: 200, height: 200))
    _ = await render(host, counter: counter)
    _ = await render(host, enabled: false, counter: counter)
    #expect(!host.shortcuts.matches(KeyEvent(.character("z"), modifiers: .command)))
}

@Test @XUIActor
func aFocusedFieldTakesTheKeyFirst() async {
    let counter = Counter()
    let field = Text()
    let host = XUIHost(size: RenderSize(width: 200, height: 200))
    let frame = await render(host, counter: counter, field: field)
    let tap = frame.layout.tapGestures.first { $0.id == "t" }!
    let p = RenderPoint(x: Float(tap.rect.midX), y: Float(tap.rect.midY))
    _ = host.pointer(PointerEvent(phase: .began, position: p), in: frame)
    _ = host.pointer(PointerEvent(phase: .ended, position: p), in: frame)
    #expect(host.textFocus.focusedID == "t")
    // Typing is the field's. ⌘Z is no text key, but the shortcut stays out of the way while the field has the keyboard.
    #expect(host.key(KeyEvent(.character("a"))))
    #expect(field.text == "a")
    #expect(!host.consumes(KeyEvent(.character("z"), modifiers: .command)))
    #expect(!host.key(KeyEvent(.character("z"), modifiers: .command)))
    #expect(counter.all.isEmpty)
}
