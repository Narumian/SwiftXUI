import XRender
import XUI

/// The system clipboard as far as text fields are concerned.
public protocol XClipboard: AnyObject, Sendable {
    var string: String? { get set }
}

/// Used until the platform shell supplies the real pasteboard, and in tests.
public final class InMemoryClipboard: XClipboard, @unchecked Sendable {
    public var string: String?
    public init(_ string: String? = nil) { self.string = string }
}

/// What a key press means to a focused text field.
enum TextKeyCommand: Equatable {
    case input(TextInputEvent)
    case focusNext(reverse: Bool)
    case copy, cut, paste
}

enum TextKeyMap {
    /// Translates a key press into a text command, or nil when the key is not a text key
    /// (so command shortcuts such as ⌘Q still reach the app).
    static func command(for event: KeyEvent) -> TextKeyCommand? {
        let m = event.modifiers
        let shift = m.contains(.shift)
        let command = m.contains(.command)
        let control = m.contains(.control)
        let option = m.contains(.option)

        switch event.key {
        case .character(let text):
            if command {
                switch text.lowercased() {
                case "a": return .input(.selectAll)
                case "c": return .copy
                case "x": return .cut
                case "v": return .paste
                default: return nil
                }
            }
            if control {
                // Emacs-style editing keys, as in every native macOS text field.
                switch text.lowercased() {
                case "a": return .input(.move(.lineStart, extend: shift))
                case "e": return .input(.move(.lineEnd, extend: shift))
                case "b": return .input(.move(.left, extend: shift))
                case "f": return .input(.move(.right, extend: shift))
                case "h": return .input(.deleteBackward)
                case "d": return .input(.deleteForward)
                case "u": return .input(.deleteToLineStart)
                case "w": return .input(.deleteWordBackward)
                default: return nil
                }
            }
            return text.isEmpty ? nil : .input(.insert(text))
        case .backspace:
            if command { return .input(.deleteToLineStart) }
            if option || control { return .input(.deleteWordBackward) }
            return .input(.deleteBackward)
        case .deleteForward:
            return .input(.deleteForward)
        case .left:
            if command { return .input(.move(.lineStart, extend: shift)) }
            return .input(.move(option || control ? .wordLeft : .left, extend: shift))
        case .right:
            if command { return .input(.move(.lineEnd, extend: shift)) }
            return .input(.move(option || control ? .wordRight : .right, extend: shift))
        case .home, .up:
            return .input(.move(.lineStart, extend: shift))
        case .end, .down:
            return .input(.move(.lineEnd, extend: shift))
        case .returnKey:
            return .input(.submit)
        case .escape:
            return .input(.cancel)
        case .tab:
            return .focusNext(reverse: shift)
        }
    }
}

public extension XUIHost {
    /// Whether `event` is a key a focused text field would act on. A shell uses this to decide,
    /// before dispatching asynchronously, whether to swallow a key or let it reach menu shortcuts.
    static func isTextKey(_ event: KeyEvent) -> Bool {
        TextKeyMap.command(for: event) != nil
    }

    /// Whether the key is taken by the app right now: by the focused text field, or else by a `.keyboardShortcut`.
    /// A shell asks this before dispatching a key asynchronously, so it can leave every other key (⌘Q) to the system.
    func consumes(_ event: KeyEvent) -> Bool {
        if textFocus.focusedID != nil, Self.isTextKey(event) { return true }
        return shortcuts.matches(event, textEditing: textFocus.focusedID != nil)
    }

    /// Routes a hardware key press to the focused text field, or else to a shortcut. Returns whether it
    /// was consumed; when no field has focus nothing is consumed, so the app's own
    /// shortcuts and the gamepad/keyboard focus navigation keep working.
    @discardableResult
    @XUIActor
    func key(_ event: KeyEvent) -> Bool {
        defer { invalidateLayoutAfterInput() }
        guard textFocus.focusedID != nil, let command = TextKeyMap.command(for: event) else {
            return shortcuts.perform(event, textEditing: textFocus.focusedID != nil)
        }
        switch command {
        case .input(let input):
            return textFocus.send(input)
        case .focusNext(let reverse):
            return textFocus.focusNext(reverse: reverse)
        case .copy:
            if let selected = textFocus.selectedText, !selected.isEmpty { clipboard.string = selected }
            return true
        case .cut:
            if let selected = textFocus.selectedText, !selected.isEmpty {
                clipboard.string = selected
                textFocus.send(.deleteBackward)
            }
            return true
        case .paste:
            if let pasted = clipboard.string, !pasted.isEmpty { textFocus.send(.insert(pasted)) }
            return true
        }
    }

    /// Delivers text input that did not come from a key press: the XUI on-screen
    /// keyboard, or an OS input method's composition.
    @discardableResult
    @XUIActor
    func textInput(_ event: TextInputEvent) -> Bool {
        defer { invalidateLayoutAfterInput() }
        return textFocus.send(event)
    }
}

public extension KeyShortcutTable {
    func matches(_ event: KeyEvent, textEditing: Bool = false) -> Bool {
        guard let shortcut = KeyboardShortcut(event) else { return false }
        return contains(shortcut, textEditing: textEditing)
    }

    @discardableResult
    func perform(_ event: KeyEvent, textEditing: Bool = false) -> Bool {
        guard let shortcut = KeyboardShortcut(event) else { return false }
        return perform(shortcut, textEditing: textEditing)
    }
}

extension KeyboardShortcut {
    /// The shortcut a key press stands for: a typed key by its text, a key without text (arrows, return) by its name.
    /// Nil for keys no shortcut can name (tab, escape and the like are named too; see `Named`).
    init?(_ event: KeyEvent) {
        let key: String
        switch event.key {
        case .character(let text):
            guard !text.isEmpty else { return nil }
            key = text == " " ? Named.space.rawValue : text
        case .up: key = Named.upArrow.rawValue
        case .down: key = Named.downArrow.rawValue
        case .left: key = Named.leftArrow.rawValue
        case .right: key = Named.rightArrow.rawValue
        case .home: key = Named.home.rawValue
        case .end: key = Named.end.rawValue
        case .returnKey: key = Named.returnKey.rawValue
        case .escape: key = Named.escape.rawValue
        case .tab: key = Named.tab.rawValue
        case .backspace: key = Named.backspace.rawValue
        case .deleteForward: key = Named.deleteForward.rawValue
        }
        var modifiers: ShortcutModifiers = []
        if event.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if event.modifiers.contains(.control) { modifiers.insert(.control) }
        if event.modifiers.contains(.option) { modifiers.insert(.option) }
        if event.modifiers.contains(.command) { modifiers.insert(.command) }
        self.init(key, modifiers: modifiers)
    }
}
