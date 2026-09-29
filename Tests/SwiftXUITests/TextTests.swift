import Testing
@testable import SwiftXUI

private func renderedLabels(_ view: some XView, canvas: Size = Size(width: 300, height: 200)) -> [RecordingCanvas.Label] {
    let surface = RecordingCanvas()
    LayoutHost(canvas: canvas).render(view, into: surface)
    return surface.labels
}

@Test func textStaysOnOneLineWhenItFitsTheOfferedWidth() {
    let labels = renderedLabels(Text("Hello", size: 10).frame(width: 200))
    #expect(labels.map(\.string) == ["Hello"])
}

@Test func textWrapsOnWordBoundariesWhenNarrowerThanItsContent() {
    // "one two three" (13 chars) at size 10 with the test canvas's 0.6 width
    // factor is 78pt wide; a 40pt box can't hold more than one short word.
    let labels = renderedLabels(Text("one two three", size: 10).frame(width: 40))
    #expect(labels.map(\.string) == ["one", "two", "three"])
}

@Test func cjkTextWrapsPerCharacterSinceItCarriesNoSpaces() {
    // 5 chars at 6pt each (size 10 × the fake measurer's 0.6 factor) = 30pt;
    // a 15pt box holds at most 2.
    let labels = renderedLabels(Text("こんにちは", size: 10).frame(width: 15))
    #expect(labels.map(\.string) == ["こん", "にち", "は"])
}

@Test func explicitNewlinesAreHardBreaksEvenWhenTheLineWouldFit() {
    let labels = renderedLabels(Text("one\ntwo", size: 10).frame(width: 200))
    #expect(labels.map(\.string) == ["one", "two"])
}

@Test func lineLimitTruncatesAndEllipsisesTheLastVisibleLine() {
    let labels = renderedLabels(Text("one two three", size: 10).lineLimit(2).frame(width: 40))
    #expect(labels.map(\.string) == ["one", "two…"])
}

@Test func wrappedLinesStackVerticallyByTheSingleLineHeight() {
    let labels = renderedLabels(Text("one two three", size: 10).frame(width: 40))
    let lineHeight = labels[1].rect.y - labels[0].rect.y
    #expect(lineHeight > 0)
    #expect(labels[2].rect.y - labels[1].rect.y == lineHeight)
    #expect(labels.allSatisfy { $0.rect.height == lineHeight })
}

@Test func wrappedTextHugsItsWidestLineRatherThanTheOfferedWidth() {
    // Box offers 60pt; "one two" (42pt) fits, "one two three" (78pt) doesn't,
    // so it wraps to ["one two", "three"] and hugs the widest of those (42pt).
    let labels = renderedLabels(Text("one two three", size: 10).frame(width: 60))
    #expect(labels.map(\.string) == ["one two", "three"])
    #expect(labels.allSatisfy { $0.rect.width == 42 })
}
