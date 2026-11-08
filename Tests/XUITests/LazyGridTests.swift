import Testing
@testable import XUI

private let gridCanvas = Size(width: 100, height: 200)

@XUIActor
private func renderGrid(
    axis: Axis = .vertical, tracks: Int = 2, count: Int = 1000, length: GridItemLength = .fixed(50),
    spacing: Double = 0, resetKey: String = "", canvas: Size = gridCanvas, store: StateStore
) async -> (RecordingCanvas, RenderResult) {
    let view = LazyGrid(axis: axis, tracks: tracks, count: count, length: length, spacing: spacing, resetKey: resetKey) { index, size in
        Color.red.frame(width: .pt(size.width), height: .pt(size.height))
            .onTapGesture(id: "cell.\(index)", label: "cell \(index)") {}
    }
    let surface = RecordingCanvas()
    let result = await LayoutHost(canvas: canvas).render(view, into: surface, store: store)
    return (surface, result)
}

@Test
func gridGeometryFindsVisibleRows() {
    let geometry = LazyGridGeometry(axis: .vertical, tracks: 2, count: 1000, spacing: 0, length: .fixed(50), viewport: gridCanvas)
    #expect(geometry.rowCount == 500)
    #expect(geometry.visibleRows(at: 0) == 0..<4)
    #expect(geometry.visibleRows(at: 25) == 0..<5)
    #expect(geometry.visibleRows(at: 100) == 2..<6)
    #expect(geometry.maxOffset == 500 * 50 - 200)
}

@Test
func gridAnchorRoundTripsThroughOffset() {
    let geometry = LazyGridGeometry(axis: .vertical, tracks: 3, count: 100, spacing: 4, length: .fixed(46), viewport: gridCanvas)
    let anchor = geometry.anchor(for: 333)
    #expect(anchor.item % 3 == 0)
    #expect(geometry.offset(anchorItem: anchor.item, intra: anchor.intra) == 333)
}

@Test
func gridAspectLengthFollowsTheCrossExtent() {
    let vertical = LazyGridGeometry(axis: .vertical, tracks: 2, count: 10, spacing: 0, length: .aspect(2), viewport: Size(width: 100, height: 100))
    #expect(vertical.itemSize == Size(width: 50, height: 25))
    let horizontal = LazyGridGeometry(axis: .horizontal, tracks: 2, count: 10, spacing: 0, length: .aspect(2), viewport: Size(width: 100, height: 100))
    #expect(horizontal.itemSize == Size(width: 100, height: 50))
}

@Test @XUIActor
func gridBuildsOnlyTheVisibleRows() async {
    let (surface, result) = await renderGrid(store: StateStore())
    #expect(surface.fills.count == 8)
    #expect(result.tapGestures.count == 8)
    #expect(surface.fills.first?.rect == Rect(x: 0, y: 0, width: 50, height: 50))
    #expect(surface.fills.last?.rect == Rect(x: 50, y: 150, width: 50, height: 50))
}

@Test @XUIActor
func gridBuildsNothingForAnEmptyCollection() async {
    let (surface, result) = await renderGrid(count: 0, store: StateStore())
    #expect(surface.fills.isEmpty)
    #expect(result.dragGestures.count == 1)
}

@Test @XUIActor
func horizontalGridScrollsAlongX() async {
    let (surface, _) = await renderGrid(axis: .horizontal, tracks: 2, count: 1000, length: .fixed(50), canvas: Size(width: 200, height: 100), store: StateStore())
    #expect(surface.fills.count == 8)
    #expect(surface.fills.last?.rect == Rect(x: 150, y: 50, width: 50, height: 50))
}

@Test @XUIActor
func gridScrollsWhenDragged() async {
    let store = StateStore()
    let (_, initial) = await renderGrid(store: store)
    var runtime = GestureRuntime()
    let h1 = runtime.handle(PointerInput(id: 1, phase: .began, position: Point(x: 50, y: 150)), in: initial)
    #expect(h1)
    let h2 = runtime.handle(PointerInput(id: 1, phase: .moved, position: Point(x: 50, y: 70)), in: initial)
    #expect(h2)
    let h3 = runtime.handle(PointerInput(id: 1, phase: .ended, position: Point(x: 50, y: 70)), in: initial)
    #expect(h3)

    let (surface, _) = await renderGrid(store: store)
    #expect(surface.fills.first?.rect == Rect(x: 0, y: -30, width: 50, height: 50))
}

@Test @XUIActor
func gridStaysInsideItsContent() async {
    let store = StateStore()
    let (_, initial) = await renderGrid(count: 6, store: store)
    var runtime = GestureRuntime()
    _ = runtime.handle(PointerInput(id: 1, phase: .began, position: Point(x: 50, y: 190)), in: initial)
    _ = runtime.handle(PointerInput(id: 1, phase: .moved, position: Point(x: 50, y: 0)), in: initial)
    _ = runtime.handle(PointerInput(id: 1, phase: .ended, position: Point(x: 50, y: 0)), in: initial)

    // 3 rows of 50 = 150 < 200: nothing to scroll, the first row stays put.
    let (surface, _) = await renderGrid(count: 6, store: store)
    #expect(surface.fills.first?.rect == Rect(x: 0, y: 0, width: 50, height: 50))
}

@Test @XUIActor
func gridKeepsItsPlaceWhenTheTrackCountChanges() async {
    let store = StateStore()
    let (_, initial) = await renderGrid(tracks: 2, store: store)
    var runtime = GestureRuntime()
    _ = runtime.handle(PointerInput(id: 1, phase: .began, position: Point(x: 50, y: 190)), in: initial)
    _ = runtime.handle(PointerInput(id: 1, phase: .moved, position: Point(x: 50, y: 40)), in: initial)
    _ = runtime.handle(PointerInput(id: 1, phase: .ended, position: Point(x: 50, y: 40)), in: initial)
    _ = await renderGrid(tracks: 2, store: store)

    // 150 pt scrolled with 2 columns = 3 rows = items 6… ; with 3 columns row 2 starts at item 6.
    let (surface, _) = await renderGrid(tracks: 3, store: store)
    let top = surface.fills.first?.rect
    #expect(top?.y == 0)
}

@Test @XUIActor
func gridReturnsToTheStartWhenItsResetKeyChanges() async {
    let store = StateStore()
    let (_, initial) = await renderGrid(resetKey: "a", store: store)
    var runtime = GestureRuntime()
    _ = runtime.handle(PointerInput(id: 1, phase: .began, position: Point(x: 50, y: 190)), in: initial)
    _ = runtime.handle(PointerInput(id: 1, phase: .moved, position: Point(x: 50, y: 40)), in: initial)
    _ = runtime.handle(PointerInput(id: 1, phase: .ended, position: Point(x: 50, y: 40)), in: initial)
    _ = await renderGrid(resetKey: "a", store: store)

    let (surface, _) = await renderGrid(resetKey: "b", store: store)
    #expect(surface.fills.first?.rect == Rect(x: 0, y: 0, width: 50, height: 50))
}
