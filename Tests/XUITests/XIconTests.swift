import Testing
@testable import XUI

private let iconCanvas = Size(width: 100, height: 100)

@XUIActor private func paths(of icon: XIcon) async -> [RecordingCanvas.RecordedPath] {
    let recording = RecordingCanvas()
    _ = await LayoutHost(canvas: iconCanvas).render(icon.frame(width: 40, height: 40, alignment: .topLeading), into: recording)
    return recording.paths
}

@Test @XUIActor func theCloseIconIsTwoCrossingLinesInItsSquare() async {
    let drawn = await paths(of: XIcon(.close, size: 40, color: .red, lineWidth: 3))
    #expect(drawn.count == 2)
    #expect(drawn.allSatisfy { $0.color == .red && $0.lineWidth == 3 && $0.path.subpaths(fittedIn: $0.rect).first?.points.count == 2 })
    #expect(drawn.allSatisfy { $0.rect.x >= 0 && $0.rect.y >= 0 && $0.rect.x + $0.rect.width <= 40 && $0.rect.y + $0.rect.height <= 40 })
}

@Test @XUIActor func undoIsAnArcWithAHeadAndRedoIsItsMirrorImage() async {
    let undo = await paths(of: XIcon(.undo, size: 40))
    let redo = await paths(of: XIcon(.redo, size: 40))
    #expect(undo.count == 2 && redo.count == 2)
    #expect(undo[0].lineWidth != nil && undo[1].lineWidth == nil)          // the arc is stroked, the head is filled
    let a = undo[0].rect, b = redo[0].rect
    #expect(abs((a.x + a.width / 2) + (b.x + b.width / 2) - 40) < 0.01)     // mirrored about the middle of the square
    #expect(abs(a.width - b.width) < 0.01 && abs(a.y - b.y) < 0.01)
}

@Test @XUIActor func everyIconKindDrawsInsideItsSquare() async {
    let kinds: [XIcon.Kind] = [.close, .undo, .redo, .reload, .play, .stop, .more, .chevronUp, .chevronDown]
    for kind in kinds {
        let drawn = await paths(of: XIcon(kind, size: 40))
        #expect(!drawn.isEmpty, "\(kind) draws nothing")
        #expect(drawn.allSatisfy { $0.rect.x >= -0.01 && $0.rect.y >= -0.01 && $0.rect.x + $0.rect.width <= 40.01 && $0.rect.y + $0.rect.height <= 40.01 }, "\(kind) leaves its square")
    }
    #expect(await paths(of: XIcon(.more, size: 40)).count == 3)
    #expect(await paths(of: XIcon(.play, size: 40)).allSatisfy { $0.lineWidth == nil })       // filled
    #expect(await paths(of: XIcon(.chevronDown, size: 40)).allSatisfy { $0.lineWidth != nil }) // stroked
}
