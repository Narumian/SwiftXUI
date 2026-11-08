import Testing
@testable import XUI

private func edit(_ text: String, caret: Int? = nil, _ events: TextInputEvent...) -> TextEditing {
    var state = TextEditing(text: text, caret: caret)
    for event in events { state.apply(event) }
    return state
}

@Test func insertTypesAtTheCaret() {
    let s = edit("ab", caret: 1, .insert("X"))
    #expect(s.text == "aXb" && s.caret == 2)
}

@Test func insertReplacesTheSelection() {
    let s = edit("hello", .selectAll, .insert("hi"))
    #expect(s.text == "hi" && s.caret == 2 && s.selection == nil)
}

@Test func deleteBackwardRemovesOneCharacterNotOneScalar() {
    // A family emoji is one character made of several scalars.
    let s = edit("a👨‍👩‍👧b", .move(.left, extend: false), .deleteBackward)
    #expect(s.text == "ab" && s.caret == 1)
    let accented = edit("e\u{301}", .deleteBackward)
    #expect(accented.text.isEmpty)
}

@Test func deleteAtTheEdgesDoesNothing() {
    #expect(edit("", .deleteBackward, .deleteForward).text == "")
    #expect(edit("ab", caret: 0, .deleteBackward).text == "ab")
    #expect(edit("ab", caret: 2, .deleteForward).text == "ab")
}

@Test func deleteForwardRemovesTheNextCharacter() {
    let s = edit("abc", caret: 1, .deleteForward)
    #expect(s.text == "ac" && s.caret == 1)
}

@Test func deleteRemovesASelectionAsOne() {
    let s = edit("abcd", caret: 1, .move(.right, extend: true), .move(.right, extend: true), .deleteBackward)
    #expect(s.text == "ad" && s.caret == 1)
}

@Test func wordMovesAndDeletes() {
    var s = TextEditing(text: "foo bar_1  baz")
    s.apply(.move(.wordLeft, extend: false))
    #expect(s.caret == 11)
    s.apply(.move(.wordLeft, extend: false))
    #expect(s.caret == 4)
    s.apply(.move(.wordRight, extend: false))
    #expect(s.caret == 9)
    s.apply(.deleteWordBackward)
    #expect(s.text == "foo   baz" && s.caret == 4)
}

@Test func deleteToLineStartClearsEverythingBeforeTheCaret() {
    let s = edit("hello world", caret: 5, .deleteToLineStart)
    #expect(s.text == " world" && s.caret == 0)
}

@Test func arrowCollapsesASelectionToItsEdge() {
    var s = TextEditing(text: "abcd", caret: 1)
    s.apply(.move(.right, extend: true)); s.apply(.move(.right, extend: true))
    #expect(s.selection == 1..<3)
    s.apply(.move(.left, extend: false))
    #expect(s.caret == 1 && s.selection == nil)
    s.select(from: 1, to: 3)
    s.apply(.move(.right, extend: false))
    #expect(s.caret == 3 && s.selection == nil)
}

@Test func shiftHomeAndEndSelect() {
    var s = TextEditing(text: "abc", caret: 1)
    s.apply(.move(.lineEnd, extend: true))
    #expect(s.selection == 1..<3)
    s.apply(.move(.lineStart, extend: true))
    #expect(s.selection == 0..<1)
}

@Test func newlinesAndControlCharactersNeverEnterASingleLine() {
    let s = edit("", .insert("a\nb\tc\u{7}d"))
    #expect(s.text == "a b cd")
}

@Test func compositionReplacesItselfAndKeepsTheCaretInside() {
    var s = TextEditing(text: "x")
    s.apply(.setMarked("k", caret: nil))
    #expect(s.text == "xk" && s.marked == 1..<2)
    s.apply(.setMarked("ka", caret: nil))
    #expect(s.text == "xka" && s.marked == 1..<3)
    s.apply(.setMarked("か", caret: 1))
    #expect(s.text == "xか" && s.marked == 1..<2 && s.caret == 2)
    s.apply(.insert("科"))
    #expect(s.text == "x科" && s.marked == nil && s.caret == 2)
}

@Test func compositionCanBeCommittedOrCancelled() {
    var s = TextEditing(text: "")
    s.apply(.setMarked("nya", caret: nil))
    s.apply(.commitMarked)
    #expect(s.text == "nya" && s.marked == nil)
    s.apply(.setMarked("zz", caret: nil))
    s.apply(.cancelMarked)
    #expect(s.text == "nya" && s.marked == nil && s.caret == 3)
}

@Test func backspaceDuringCompositionEditsTheComposition() {
    var s = TextEditing(text: "")
    s.apply(.setMarked("ab", caret: nil))
    s.apply(.deleteBackward)
    // The whole composition is the unit being edited; the input method re-sends the shortened one.
    #expect(s.text == "" && s.marked == nil)
}

@Test func movingTheCaretConfirmsAComposition() {
    var s = TextEditing(text: "")
    s.apply(.setMarked("ka", caret: nil))
    s.apply(.move(.left, extend: false))
    #expect(s.marked == nil && s.text == "ka" && s.caret == 1)
}

@Test func tapPlacesTheCaretAndClampsIt() {
    var s = TextEditing(text: "abc")
    s.place(caret: 1)
    #expect(s.caret == 1)
    s.place(caret: 99)
    #expect(s.caret == 3)
    s.place(caret: -4)
    #expect(s.caret == 0)
}

@Test func doubleTapSelectsTheWord() {
    var s = TextEditing(text: "open file.txt now")
    s.selectWord(at: 6)
    #expect(s.selection == 5..<9)
    s.selectWord(at: 4)   // on the space
    #expect(s.selection != nil)
}

@Test func externalChangesAreAdoptedWithAValidCaret() {
    var s = TextEditing(text: "hello", caret: 5)
    s.reconcile(with: "hi")
    #expect(s.text == "hi" && s.caret == 2)
    s.reconcile(with: "hi")
    #expect(s.caret == 2)
}

@Test func applyReportsWhetherTheTextChanged() {
    var s = TextEditing(text: "ab")
    let inserted = s.apply(.insert("c"))
    let moved = s.apply(.move(.left, extend: false))
    let submitted = s.apply(.submit)
    #expect(inserted)
    #expect(!moved)
    #expect(!submitted)
}

@Test func prefixAndSubstringFollowCharacterOffsets() {
    let s = TextEditing(text: "a👍b")
    #expect(s.prefix(2) == "a👍")
    #expect(s.substring(1..<2) == "👍")
    #expect(s.count == 3)
}
