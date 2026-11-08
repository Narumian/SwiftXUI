import Foundation

/// What a field wants typed into it. The on-screen keyboard picks its layout
/// from this; an OS input method would pick its keyboard type from it too.
public enum TextInputKind: Sendable, Equatable {
    case text
    /// Digits plus the sign and decimal point.
    case number
}

/// The label and meaning of the return key while a field is focused.
public enum KeyboardPolicy: Sendable, Equatable {
    case always, never
}

public enum TextReturnKey: Sendable, Equatable {
    case done, search, go, next
}

/// The one place that knows which text field has the keyboard. Hosts share a
/// single instance with the views (as an environment object) so that
///  - a tap on a field focuses it,
///  - key events, the on-screen keyboard and an input method all reach the
///    focused field through `send(_:)`,
///  - a tap anywhere else dismisses the keyboard.
///
/// Fields register themselves while they draw, so the store always reflects the
/// frame the user is looking at. Directional (gamepad) focus is a separate
/// concept, `FocusStore`.
public final class TextFocusStore: @unchecked Sendable {
    public struct Field: Sendable, Equatable {
        public var id: String
        public var rect: Rect
        public var kind: TextInputKind
        public var returnKey: TextReturnKey
    }

    private struct Entry {
        var field: Field
        var handler: @Sendable (TextInputEvent) -> Void
        var selectedText: @Sendable () -> String?
    }

    private let lock = NSLock()
    private var focusedIDValue: String?
    private var entries: [String: Entry] = [:]
    private var building: [String: Entry] = [:]
    private var keepRects: [Rect] = []
    private var buildingKeepRects: [Rect] = []
    private var revisionValue = 0
    private var keyboardRect: Rect?
    private var buildingKeyboardRect: Rect?
    private var keyboardPointerHandler: (@Sendable (PointerInput) -> Void)?
    private var buildingKeyboardPointerHandler: (@Sendable (PointerInput) -> Void)?
    private var claimedPointers: Set<Int> = []

    /// Whether the XUI on-screen keyboard appears while a field is focused. A shell
    /// that always has a physical keyboard (a desktop Mac) can set `.never`.
    public var keyboardPolicy: KeyboardPolicy {
        get { lock.withLock { keyboardPolicyValue } }
        set { lock.withLock { keyboardPolicyValue = newValue } }
    }
    private var keyboardPolicyValue = KeyboardPolicy.always

    /// Called once per on-screen key press, for the shell's haptic / click.
    public var onKeyPress: (@Sendable () -> Void)? {
        get { lock.withLock { onKeyPressValue } }
        set { lock.withLock { onKeyPressValue = newValue } }
    }
    private var onKeyPressValue: (@Sendable () -> Void)?

    public init() {}

    /// Whether a focused field currently wants the on-screen keyboard.
    public var wantsKeyboard: Bool {
        lock.withLock { focusedIDValue.flatMap { entries[$0] } != nil && keyboardPolicyValue == .always }
    }

    // MARK: - Reading

    public var focusedID: String? { lock.withLock { focusedIDValue } }

    /// The focused field as drawn in the latest frame, if it is on screen.
    public var focusedField: Field? {
        lock.withLock { focusedIDValue.flatMap { entries[$0]?.field } }
    }

    public func isFocused(_ id: String) -> Bool { lock.withLock { focusedIDValue == id } }

    /// Changes whenever focus moves, so a host can tell when to refresh.
    public var revision: Int { lock.withLock { revisionValue } }

    /// Fields drawn in the latest frame, in reading order (top to bottom, then left to right).
    public var fields: [Field] {
        lock.withLock { entries.values.map(\.field).sorted(by: Self.readingOrder) }
    }

    // MARK: - Focus

    public func focus(_ id: String) {
        lock.withLock {
            guard focusedIDValue != id else { return }
            focusedIDValue = id
            revisionValue &+= 1
        }
    }

    public func blur() {
        lock.withLock {
            guard focusedIDValue != nil else { return }
            focusedIDValue = nil
            revisionValue &+= 1
        }
    }

    /// Moves focus to the next field in reading order (Tab), wrapping around;
    /// `reverse` goes the other way (Shift-Tab). Returns whether focus moved.
    @discardableResult
    public func focusNext(reverse: Bool = false) -> Bool {
        let order = fields
        guard !order.isEmpty else { return false }
        return lock.withLock {
            guard let current = focusedIDValue, let index = order.firstIndex(where: { $0.id == current }) else {
                focusedIDValue = (reverse ? order.last : order.first)?.id
                revisionValue &+= 1
                return true
            }
            guard order.count > 1 else { return false }
            let next = (index + (reverse ? order.count - 1 : 1)) % order.count
            focusedIDValue = order[next].id
            revisionValue &+= 1
            return true
        }
    }

    // MARK: - Input

    /// Delivers `event` to the focused field. Returns whether a field took it, so
    /// a host knows whether a key press was consumed or may fall through to
    /// shortcuts.
    @discardableResult
    public func send(_ event: TextInputEvent) -> Bool {
        let handler: (@Sendable (TextInputEvent) -> Void)? = lock.withLock {
            focusedIDValue.flatMap { entries[$0]?.handler }
        }
        guard let handler else { return false }
        handler(event)
        return true
    }

    /// The focused field's selected text, for copy and cut.
    public var selectedText: String? {
        let provider: (@Sendable () -> String?)? = lock.withLock { focusedIDValue.flatMap { entries[$0]?.selectedText } }
        return provider?()
    }

    /// Whether a press at `point` should keep the keyboard: it landed on a text
    /// field or on a region that declared itself part of the keyboard.
    public func keepsFocus(at point: Point) -> Bool {
        lock.withLock {
            entries.values.contains { $0.field.rect.contains(point) }
                || keepRects.contains { $0.contains(point) }
                || (keyboardRect?.contains(point) ?? false)
        }
    }

    /// Called by a host for every pointer press. Dismisses the keyboard when the
    /// press landed outside any field and outside the keyboard. Returns whether
    /// focus was dropped.
    @discardableResult
    public func blurIfOutside(_ point: Point) -> Bool {
        guard focusedID != nil, !keepsFocus(at: point) else { return false }
        blur()
        return true
    }

    // MARK: - Frame bookkeeping (called by hosts and fields)

    /// Starts collecting the fields of a new frame.
    public func beginFrame() {
        lock.withLock {
            building.removeAll(keepingCapacity: true)
            buildingKeepRects.removeAll(keepingCapacity: true)
            buildingKeyboardRect = nil
            buildingKeyboardPointerHandler = nil
        }
    }

    /// Publishes the collected frame. A focused field that is no longer drawn
    /// (its sheet closed, its page changed) loses focus.
    public func endFrame() {
        lock.withLock {
            entries = building
            keepRects = buildingKeepRects
            keyboardRect = buildingKeyboardRect
            keyboardPointerHandler = buildingKeyboardPointerHandler
            if let id = focusedIDValue, entries[id] == nil {
                focusedIDValue = nil
                revisionValue &+= 1
            }
        }
    }

    public func record(
        id: String, rect: Rect, kind: TextInputKind, returnKey: TextReturnKey,
        selectedText: @escaping @Sendable () -> String? = { nil },
        handler: @escaping @Sendable (TextInputEvent) -> Void
    ) {
        lock.withLock {
            let entry = Entry(
                field: Field(id: id, rect: rect, kind: kind, returnKey: returnKey),
                handler: handler, selectedText: selectedText
            )
            building[id] = entry
            // Outside a host's frame loop (a test rendering directly) there is no
            // endFrame; make the field reachable immediately.
            if !inFrameLoop { entries[id] = entry }
        }
    }

    /// Registers the on-screen keyboard for this frame. Its pointers are handled
    /// here, ahead of gesture recognition, so several fingers can type at once.
    public func recordKeyboard(rect: Rect, pointer: @escaping @Sendable (PointerInput) -> Void) {
        lock.withLock {
            buildingKeyboardRect = rect
            buildingKeyboardPointerHandler = pointer
            if !inFrameLoop { keyboardRect = rect; keyboardPointerHandler = pointer }
        }
    }

    /// Offers a pointer sample to the keyboard. A finger that went down on the
    /// keyboard belongs to it until it lifts, whatever it slides over. Returns
    /// whether the keyboard took the sample.
    public func handleKeyboardPointer(_ input: PointerInput) -> Bool {
        let handler: (@Sendable (PointerInput) -> Void)? = lock.withLock {
            switch input.phase {
            case .began:
                guard let rect = keyboardRect, rect.contains(input.position) else { return nil }
                claimedPointers.insert(input.id)
                return keyboardPointerHandler
            case .moved:
                return claimedPointers.contains(input.id) ? keyboardPointerHandler : nil
            case .ended, .cancelled:
                return claimedPointers.remove(input.id) != nil ? keyboardPointerHandler : nil
            }
        }
        guard let handler else { return false }
        handler(input)
        return true
    }

    /// Declares `rect` part of the keyboard: pressing in it keeps focus.
    public func recordKeepFocus(_ rect: Rect) {
        lock.withLock {
            buildingKeepRects.append(rect)
            if !inFrameLoop { keepRects.append(rect) }
        }
    }

    /// True once a host has started driving frames with `beginFrame`/`endFrame`.
    public var hostManagesFrames: Bool {
        get { lock.withLock { inFrameLoop } }
        set { lock.withLock { inFrameLoop = newValue } }
    }
    private var inFrameLoop = false

    static func readingOrder(_ a: Field, _ b: Field) -> Bool {
        // Fields within half a row of each other count as one line.
        if abs(a.rect.y - b.rect.y) > min(a.rect.height, b.rect.height) / 2 { return a.rect.y < b.rect.y }
        return a.rect.x < b.rect.x
    }
}
