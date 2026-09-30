import Testing
@testable import XUI

@XUIActor
private func renderedLabels(_ view: some XView, canvas: Size = Size(width: 300, height: 200)) async -> [RecordingCanvas.Label] {
    let surface = RecordingCanvas()
    await LayoutHost(canvas: canvas).render(view, into: surface)
    return surface.labels
}

@Test @XUIActor func textStaysOnOneLineWhenItFitsTheOfferedWidth() async {
    let labels = await renderedLabels(Text("Hello", size: 10).frame(width: 200))
    #expect(labels.map(\.string) == ["Hello"])
}

@Test @XUIActor func textWrapsOnWordBoundariesWhenNarrowerThanItsContent() async {
    // "one two three" (13 chars) at size 10 with the test canvas's 0.6 width
    // factor is 78pt wide; a 40pt box can't hold more than one short word.
    let labels = await renderedLabels(Text("one two three", size: 10).frame(width: 40))
    #expect(labels.map(\.string) == ["one", "two", "three"])
}

@Test @XUIActor func cjkTextWrapsPerCharacterSinceItCarriesNoSpaces() async {
    // 5 chars at 6pt each (size 10 × the fake measurer's 0.6 factor) = 30pt;
    // a 15pt box holds at most 2.
    let labels = await renderedLabels(Text("こんにちは", size: 10).frame(width: 15))
    #expect(labels.map(\.string) == ["こん", "にち", "は"])
}

@Test @XUIActor func explicitNewlinesAreHardBreaksEvenWhenTheLineWouldFit() async {
    let labels = await renderedLabels(Text("one\ntwo", size: 10).frame(width: 200))
    #expect(labels.map(\.string) == ["one", "two"])
}

@Test @XUIActor func lineLimitTruncatesAndEllipsisesTheLastVisibleLine() async {
    let labels = await renderedLabels(Text("one two three", size: 10).lineLimit(2).frame(width: 40))
    #expect(labels.map(\.string) == ["one", "two…"])
}

@Test @XUIActor func wrappedLinesStackVerticallyByTheSingleLineHeight() async {
    let labels = await renderedLabels(Text("one two three", size: 10).frame(width: 40))
    let lineHeight = labels[1].rect.y - labels[0].rect.y
    #expect(lineHeight > 0)
    #expect(labels[2].rect.y - labels[1].rect.y == lineHeight)
    #expect(labels.allSatisfy { $0.rect.height == lineHeight })
}

@Test @XUIActor func wrappedTextHugsItsWidestLineRatherThanTheOfferedWidth() async {
    // Box offers 60pt; "one two" (42pt) fits, "one two three" (78pt) doesn't,
    // so it wraps to ["one two", "three"] and hugs the widest of those (42pt).
    let labels = await renderedLabels(Text("one two three", size: 10).frame(width: 60))
    #expect(labels.map(\.string) == ["one two", "three"])
    #expect(labels.allSatisfy { $0.rect.width == 42 })
}
