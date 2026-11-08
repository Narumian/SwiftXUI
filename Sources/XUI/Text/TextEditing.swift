import Foundation

/// A caret movement. Left/right step by user-perceived character (grapheme
/// cluster), so an emoji or an accented letter is one step, never half.
public enum TextMove: Sendable, Equatable {
    case left, right
    case wordLeft, wordRight
    case lineStart, lineEnd
}

/// Everything that can happen to a focused text field, whatever produced it:
/// a hardware key, the XUI on-screen keyboard, or an OS input method. Fields
/// consume this one stream and never care about the source.
public enum TextInputEvent: Sendable, Equatable {
    /// Typed or committed text replacing the selection (or the marked text).
    case insert(String)
    case deleteBackward
    case deleteForward
    case deleteWordBackward
    /// Deletes everything between the line start and the caret (⌘⌫).
    case deleteToLineStart
    case move(TextMove, extend: Bool)
    case selectAll
    /// Input-method composition: replaces the marked text (or the selection) with
    /// `text`, still unconfirmed. `caret` is a character offset inside `text`.
    case setMarked(String, caret: Int?)
    /// Confirms the composition as it stands.
    case commitMarked
    /// Throws the composition away.
    case cancelMarked
    /// Return / Enter. The model ignores it; the field decides what it means.
    case submit
    /// Escape. The model ignores it; the field decides what it means.
    case cancel
}

/// The editable state of one single-line text field. Offsets count characters
/// (grapheme clusters), never UTF-8 or UTF-16 units, so an edit can not split
/// a user-perceived character.
///
/// `marked` is the span an input method is still composing (romaji → kana
/// before it is confirmed). It exists from day one so that adding Japanese
/// input later is a matter of feeding `.setMarked`/`.insert`, with no change to
/// the model or to any field.
public struct TextEditing: Sendable, Equatable {
    public private(set) var text: String
    /// Character offset of the caret, `0...count`.
    public private(set) var caret: Int
    /// The fixed end of a selection; `nil` when nothing is selected.
    public private(set) var anchor: Int?
    /// The composing span, if any.
    public private(set) var marked: Range<Int>?
    /// Bumped by every change, so a view can restart caret blinking on an edit.
    public private(set) var revision: Int = 0

    private var characters: [Character]

    public init(text: String = "", caret: Int? = nil) {
        self.text = text
        self.characters = Array(text)
        self.caret = min(max(0, caret ?? characters.count), characters.count)
        self.anchor = nil
        self.marked = nil
    }

    public var count: Int { characters.count }
    public var isEmpty: Bool { characters.isEmpty }

    /// The selected span, if any.
    public var selection: Range<Int>? {
        guard let anchor, anchor != caret else { return nil }
        return min(anchor, caret)..<max(anchor, caret)
    }

    /// The text before `offset`, used to measure where a caret sits.
    public func prefix(_ offset: Int) -> String {
        String(characters[0..<min(max(0, offset), characters.count)])
    }

    public func substring(_ range: Range<Int>) -> String {
        let lower = min(max(0, range.lowerBound), characters.count)
        let upper = min(max(lower, range.upperBound), characters.count)
        return String(characters[lower..<upper])
    }

    // MARK: - Applying events

    /// Applies `event`. Returns whether the text itself changed (so a caller
    /// knows to write it back to its binding).
    @discardableResult
    public mutating func apply(_ event: TextInputEvent) -> Bool {
        let before = text
        switch event {
        case .insert(let string): insert(string)
        case .deleteBackward: deleteBackward()
        case .deleteForward: deleteForward()
        case .deleteWordBackward: deleteWordBackward()
        case .deleteToLineStart: deleteToLineStart()
        case .move(let move, let extend): self.move(move, extend: extend)
        case .selectAll: selectAll()
        case .setMarked(let string, let caret): setMarked(string, caret: caret)
        case .commitMarked: commitMarked()
        case .cancelMarked: cancelMarked()
        case .submit, .cancel: break
        }
        return text != before
    }

    /// Adopts text that changed outside the field (the binding was written
    /// elsewhere). Keeps the caret near where it was and drops stale ranges.
    public mutating func reconcile(with external: String) {
        guard external != text else { return }
        let oldCaret = caret
        text = external
        characters = Array(external)
        caret = min(oldCaret, characters.count)
        anchor = nil
        marked = nil
        revision &+= 1
    }

    /// Places the caret (a tap), dropping any selection. A composition is
    /// confirmed first: tapping elsewhere commits what was being typed.
    public mutating func place(caret offset: Int) {
        commitMarked()
        caret = clamp(offset)
        anchor = nil
        revision &+= 1
    }

    /// Extends the selection to `offset`, keeping `from` fixed (a drag).
    public mutating func select(from start: Int, to end: Int) {
        commitMarked()
        anchor = clamp(start)
        caret = clamp(end)
        if anchor == caret { anchor = nil }
        revision &+= 1
    }

    /// Selects the word around `offset` (a double tap).
    public mutating func selectWord(at offset: Int) {
        commitMarked()
        let o = clamp(offset)
        var lower = o, upper = o
        while lower > 0, Self.isWordCharacter(characters[lower - 1]) { lower -= 1 }
        while upper < characters.count, Self.isWordCharacter(characters[upper]) { upper += 1 }
        if lower == upper {
            // On a space or symbol: select that run of identical-class characters.
            if o < characters.count { upper = o + 1 } else if o > 0 { lower = o - 1 }
        }
        anchor = lower
        caret = upper
        if anchor == caret { anchor = nil }
        revision &+= 1
    }

    // MARK: - Editing

    private mutating func insert(_ string: String) {
        let filtered = Self.singleLine(string)
        replace(editRange(), with: Array(filtered), newCaretOffset: nil)
    }

    private mutating func deleteBackward() {
        if marked != nil || selection != nil {
            replace(editRange(), with: [], newCaretOffset: nil)
        } else if caret > 0 {
            replace((caret - 1)..<caret, with: [], newCaretOffset: nil)
        }
    }

    private mutating func deleteForward() {
        if marked != nil || selection != nil {
            replace(editRange(), with: [], newCaretOffset: nil)
        } else if caret < characters.count {
            replace(caret..<(caret + 1), with: [], newCaretOffset: nil)
        }
    }

    private mutating func deleteWordBackward() {
        if marked != nil || selection != nil {
            replace(editRange(), with: [], newCaretOffset: nil)
        } else if caret > 0 {
            replace(wordBoundary(before: caret)..<caret, with: [], newCaretOffset: nil)
        }
    }

    private mutating func deleteToLineStart() {
        if marked != nil || selection != nil {
            replace(editRange(), with: [], newCaretOffset: nil)
        } else if caret > 0 {
            replace(0..<caret, with: [], newCaretOffset: nil)
        }
    }

    private mutating func move(_ move: TextMove, extend: Bool) {
        // Moving the caret confirms a composition rather than silently dropping it.
        commitMarked()
        let target: Int
        switch move {
        case .left:
            // Collapsing a selection with an arrow lands on its edge, like every native field.
            if !extend, let selection { target = selection.lowerBound; setCaret(target, extend: false); return }
            target = max(0, caret - 1)
        case .right:
            if !extend, let selection { target = selection.upperBound; setCaret(target, extend: false); return }
            target = min(characters.count, caret + 1)
        case .wordLeft: target = wordBoundary(before: caret)
        case .wordRight: target = wordBoundary(after: caret)
        case .lineStart: target = 0
        case .lineEnd: target = characters.count
        }
        setCaret(target, extend: extend)
    }

    private mutating func setCaret(_ target: Int, extend: Bool) {
        if extend {
            if anchor == nil { anchor = caret }
        } else {
            anchor = nil
        }
        caret = target
        if anchor == caret { anchor = nil }
        revision &+= 1
    }

    private mutating func selectAll() {
        commitMarked()
        guard !characters.isEmpty else { return }
        anchor = 0
        caret = characters.count
        revision &+= 1
    }

    // MARK: - Composition

    private mutating func setMarked(_ string: String, caret markedCaret: Int?) {
        let replacement = Array(Self.singleLine(string))
        let range = editRange()
        if replacement.isEmpty {
            replace(range, with: [], newCaretOffset: nil)
            marked = nil
            return
        }
        replace(range, with: replacement, newCaretOffset: nil)
        let start = range.lowerBound
        marked = start..<(start + replacement.count)
        let inside = min(max(0, markedCaret ?? replacement.count), replacement.count)
        caret = start + inside
    }

    private mutating func commitMarked() {
        guard marked != nil else { return }
        marked = nil
        revision &+= 1
    }

    private mutating func cancelMarked() {
        guard let range = marked else { return }
        replace(range, with: [], newCaretOffset: nil)
        marked = nil
    }

    // MARK: - Helpers

    /// What an insert replaces: the composition if there is one, else the selection, else the caret.
    private func editRange() -> Range<Int> {
        if let marked { return marked }
        if let selection { return selection }
        return caret..<caret
    }

    private mutating func replace(_ range: Range<Int>, with replacement: [Character], newCaretOffset: Int?) {
        characters.replaceSubrange(range, with: replacement)
        text = String(characters)
        caret = newCaretOffset ?? (range.lowerBound + replacement.count)
        anchor = nil
        marked = nil
        revision &+= 1
    }

    private func clamp(_ offset: Int) -> Int { min(max(0, offset), characters.count) }

    /// A field is one line: newlines and tabs become spaces, other control characters vanish.
    static func singleLine(_ string: String) -> String {
        guard string.contains(where: { $0.isNewline || $0 == "\t" || $0.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) }) else {
            return string
        }
        var result = ""
        for character in string {
            if character.isNewline || character == "\t" {
                result.append(" ")
            } else if character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                continue
            } else {
                result.append(character)
            }
        }
        return result
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Start of the word before `offset`: skips spaces/symbols first, then the word itself.
    private func wordBoundary(before offset: Int) -> Int {
        var i = offset
        while i > 0, !Self.isWordCharacter(characters[i - 1]) { i -= 1 }
        while i > 0, Self.isWordCharacter(characters[i - 1]) { i -= 1 }
        return i
    }

    /// End of the word after `offset`: skips spaces/symbols first, then the word itself.
    private func wordBoundary(after offset: Int) -> Int {
        var i = offset
        while i < characters.count, !Self.isWordCharacter(characters[i]) { i += 1 }
        while i < characters.count, Self.isWordCharacter(characters[i]) { i += 1 }
        return i
    }
}
