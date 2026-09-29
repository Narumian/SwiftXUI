import Testing
@testable import SwiftXUI

private func frames(_ view: some XView, canvas: Size = Size(width: 300, height: 200)) -> [Rect] {
    let surface = RecordingCanvas()
    LayoutHost(canvas: canvas).render(view, into: surface)
    return surface.fills.map(\.rect)
}

@Test func backgroundDoesNotChangeContentSize() {
    let view = Color.white
        .frame(width: 80, height: 50)
        .background { Color.black }

    let f = frames(view)
    #expect(f[0].isApproximately(Rect(x: 0, y: 0, width: 80, height: 50)))
    #expect(f[1].isApproximately(Rect(x: 0, y: 0, width: 80, height: 50)))
}

@Test func overlayDoesNotChangeContentSize() {
    let view = Color.black
        .frame(width: 80, height: 50)
        .overlay { Color.white.frame(width: 20, height: 10) }

    let f = frames(view)
    #expect(f[0].isApproximately(Rect(x: 0, y: 0, width: 80, height: 50)))
    #expect(f[1].isApproximately(Rect(x: 30, y: 20, width: 20, height: 10)))
}

@Test func overlayHonoursAlignment() {
    let view = Color.black
        .frame(width: 80, height: 50)
        .overlay(alignment: .bottomTrailing) {
            Color.white.frame(width: 20, height: 10)
        }

    let f = frames(view)
    #expect(f[1].isApproximately(Rect(x: 60, y: 40, width: 20, height: 10)))
}

@Test func backgroundPaintsBehindContent() {
    let view = Color.white
        .frame(width: 80, height: 50)
        .background { Color.black }

    let f = frames(view)
    #expect(f.count == 2)
    #expect(f[0].isApproximately(Rect(x: 0, y: 0, width: 80, height: 50)))
    #expect(f[1].isApproximately(Rect(x: 0, y: 0, width: 80, height: 50)))
}

// MARK: sheet

private func render(_ view: some XView, canvas: Size = Size(width: 300, height: 200)) -> RenderResult {
    LayoutHost(canvas: canvas).render(view, into: RecordingCanvas())
}

private func sheetScreen(presented: Bool, dismissed: @escaping () -> Void = {}) -> some XView {
    Color.white
        .frame(width: 300, height: 200)
        .onTapGesture(id: "base", label: "base") {}
        .control(XControl(id: "base-c", label: "base"))
        .sheet(isPresented: presented, onDismiss: dismissed) {
            Color.black
                .frame(width: .fraction(.golden), height: .fraction(.golden))
                .onTapGesture(id: "inner", label: "inner") {}
                .control(XControl(id: "inner-c", label: "inner", scope: "content"))
        }
}

@Test func sheetPaintsCentredAtFractionOfBase() {
    let surface = RecordingCanvas()
    LayoutHost(canvas: Size(width: 300, height: 200)).render(sheetScreen(presented: true), into: surface)
    let inner = surface.fills.last!.rect
    #expect(abs(inner.width - 300 * 0.618_033_988_749_895) < 0.001)
    #expect(abs(inner.height - 200 * 0.618_033_988_749_895) < 0.001)
    #expect(abs(inner.midX - 150) < 0.001 && abs(inner.midY - 100) < 0.001)
}

@Test func sheetBlocksBaseInputAndScopesItsOwnControls() {
    let r = render(sheetScreen(presented: true))
    #expect(r.tapGestures.compactMap(\.id).contains("base") == false)
    #expect(r.controls.map(\.control.id) == ["inner-c"])
    #expect(r.controls.first?.control.scope == "sheet")
}

@Test func sheetContentTapBeatsScrimAndScrimDismisses() {
    var dismissed = 0
    let r = render(sheetScreen(presented: true) { dismissed += 1 })
    var hit = ""
    if let g = r.tapGestures.first(where: { $0.rect.contains(Point(x: 150, y: 100)) }) { hit = g.id ?? "" }
    #expect(hit == "inner")
    #expect(r.tap(Point(x: 5, y: 5)))
    #expect(dismissed == 1)
}

@Test func sheetClosedLeavesBaseInteractive() {
    let r = render(sheetScreen(presented: false))
    #expect(r.tapGestures.compactMap(\.id) == ["base"])
    #expect(r.controls.map(\.control.id) == ["base-c"])
}
