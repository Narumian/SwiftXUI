import Foundation

/// Modifier keys of a shortcut. The same four a hardware keyboard reports.
public struct ShortcutModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = ShortcutModifiers(rawValue: 1 << 0)
    public static let control = ShortcutModifiers(rawValue: 1 << 1)
    public static let option = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)
}

/// A key and the modifiers held with it. Letters compare without regard to case.
public struct KeyboardShortcut: Sendable, Hashable {
    public var key: String
    public var modifiers: ShortcutModifiers
    public init(_ key: String, modifiers: ShortcutModifiers = .command) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// Keys that carry no text. Their names are never a single character, so they cannot be taken for a typed key.
    public enum Named: String, Sendable, CaseIterable {
        case upArrow = "arrow.up", downArrow = "arrow.down", leftArrow = "arrow.left", rightArrow = "arrow.right"
        case home, end, returnKey = "return", escape, tab, space
        case backspace, deleteForward = "delete.forward"
    }

    public init(_ named: Named, modifiers: ShortcutModifiers = []) {
        self.init(named.rawValue, modifiers: modifiers)
    }
}

struct ShortcutSpec: @unchecked Sendable {
    let shortcut: KeyboardShortcut
    let duringTextEditing: Bool
    /// The key focus area the shortcut belongs to; nil: it works wherever the keyboard is aimed.
    let focusID: String?
    let action: @Sendable () -> Void
}

public struct ResolvedShortcut: @unchecked Sendable {
    public let shortcut: KeyboardShortcut
    /// Whether it still runs while a text field has the keyboard.
    public let duringTextEditing: Bool
    public let focusID: String?
    let action: @Sendable () -> Void
}

/// The shortcuts of the frame on screen. A platform shell asks it, from its own thread and before it
/// dispatches a key, whether the key is taken, so it is lock-protected and swapped whole after each frame.
public final class KeyShortcutTable: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ResolvedShortcut] = []
    /// Where the keyboard is aimed: a shortcut with a `focusID` runs only while that area has it.
    public let keyFocus: KeyFocusStore

    public init(keyFocus: KeyFocusStore = KeyFocusStore()) { self.keyFocus = keyFocus }

    private func applies(_ entry: ResolvedShortcut, _ shortcut: KeyboardShortcut, textEditing: Bool, focused: String?) -> Bool {
        entry.shortcut == shortcut && (!textEditing || entry.duringTextEditing) && (entry.focusID == nil || entry.focusID == focused)
    }

    public func replace(with shortcuts: [ResolvedShortcut]) { lock.withLock { entries = shortcuts } }

    /// Whether a shortcut is declared for it. While a text field has the keyboard (`textEditing`), only the shortcuts
    /// that asked to run during text editing count.
    public func contains(_ shortcut: KeyboardShortcut, textEditing: Bool = false) -> Bool {
        let focused = keyFocus.focusedID
        return lock.withLock { entries.contains { applies($0, shortcut, textEditing: textEditing, focused: focused) } }
    }

    /// Runs the action of the shortcut. Returns whether there was one.
    @discardableResult
    public func perform(_ shortcut: KeyboardShortcut, textEditing: Bool = false) -> Bool {
        let focused = keyFocus.focusedID
        guard let action = lock.withLock({ entries.last { applies($0, shortcut, textEditing: textEditing, focused: focused) }?.action }) else { return false }
        action()
        return true
    }
}

/// `.keyboardShortcut(_:modifiers:isEnabled:action:)`: a key combination that runs `action` while this view is on
/// screen and takes input. A focused text field gets a key before any shortcut does, and keeps the shortcuts that
/// do not say `duringTextEditing` from running.
public struct _KeyboardShortcutModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let shortcut: KeyboardShortcut
    let isEnabled: Bool
    let duringTextEditing: Bool
    let focusID: String?
    let action: @Sendable () -> Void

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let node = LayoutNode(layout: PassthroughLayout(), children: await lower(content, id: id.child(type: Content.self), store: store))
        if isEnabled { node.shortcut = ShortcutSpec(shortcut: shortcut, duringTextEditing: duringTextEditing, focusID: focusID, action: action) }
        return [node]
    }
}

public extension XView {
    /// Runs `action` when `key` is pressed with `modifiers` while this view is on screen. A disabled view
    /// (`isEnabled` false) does not take the key, and neither does one behind a sheet. While a text field has the
    /// keyboard the shortcut stays out of the way (the key is left to the field and to the system) unless
    /// `duringTextEditing` is true.
    func keyboardShortcut(
        _ key: String,
        modifiers: ShortcutModifiers = .command,
        isEnabled: Bool = true,
        duringTextEditing: Bool = false,
        focusID: String? = nil,
        action: @escaping @Sendable () -> Void
    ) -> _KeyboardShortcutModifier<Self> {
        _KeyboardShortcutModifier(content: self, shortcut: KeyboardShortcut(key, modifiers: modifiers), isEnabled: isEnabled,
                                  duringTextEditing: duringTextEditing, focusID: focusID, action: action)
    }

    /// The same for a key that carries no text (an arrow, Return, Escape). With `focusID`, it works only while the
    /// keyboard is aimed at that `.keyFocusArea`.
    func keyboardShortcut(
        _ key: KeyboardShortcut.Named,
        modifiers: ShortcutModifiers = [],
        isEnabled: Bool = true,
        duringTextEditing: Bool = false,
        focusID: String? = nil,
        action: @escaping @Sendable () -> Void
    ) -> _KeyboardShortcutModifier<Self> {
        _KeyboardShortcutModifier(content: self, shortcut: KeyboardShortcut(key, modifiers: modifiers), isEnabled: isEnabled,
                                  duringTextEditing: duringTextEditing, focusID: focusID, action: action)
    }
}
