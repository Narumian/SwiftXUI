import Testing
@testable import XUI

private let canvas = Size(width: 300, height: 200)

private func run(_ view: some XView) -> (RecordingCanvas, RenderResult) {
    let surface = RecordingCanvas()
    let result = LayoutHost(canvas: canvas).render(view, into: surface)
    return (surface, result)
}

// MARK: Text

@Test func textMeasuresThroughTheCanvasMeasurer() {
    // RecordingCanvas.measureText: width = count * size * 0.6, height = size * 1.3
    let (surface, _) = run(Text("ABCD", size: 10))
    #expect(surface.labels.count == 1)
    #expect(surface.labels[0].rect.isApproximately(Rect(x: 0, y: 0, width: 24, height: 13)))
}

@Test func textCanSelectAFontRoleAndOutline() {
    let (surface, _) = run(
        Text("28", size: 20, color: .white)
            .font(.display)
            .outline(width: 4)
    )

    #expect(surface.labels[0].rect.isApproximately(Rect(x: 0, y: 0, width: 32, height: 26)))
    #expect(surface.labels[0].font == .display)
    #expect(surface.labels[0].color == .white)
    #expect(surface.labels[0].outline?.width == 4)
}

@Test func textInsideHStackTakesItsIntrinsicWidth() {
    let view = HStack(spacing: 0) {
        Text("AB", size: 10)          // width 12, fixed
        Color.white                    // flexible, takes the remaining width and full height
    }
    let (surface, _) = run(view)
    #expect(surface.labels[0].rect.width == 12)
    #expect(surface.fills[0].rect.isApproximately(Rect(x: 12, y: 0, width: 288, height: 200)))
}

// MARK: GeometryReader

@Test func geometryReaderReceivesItsResolvedSize() {
    let view = GeometryReader { proxy in
        Color.black.frame(width: proxy.size.width / 2, height: proxy.size.height)
    }
    let (surface, _) = run(view)
    #expect(surface.fills[0].rect.isApproximately(Rect(x: 0, y: 0, width: 150, height: 200)))
}

@Test func geometryReaderExposesItsResolvedFrame() {
    var seen = Rect.zero
    func capture(_ frame: Rect) -> Color {
        seen = frame
        return .clear
    }
    let view = VStack(spacing: 0) {
        Color.clear.frame(height: 20)
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                capture(proxy.frame)
                Color.black
            }
        }
        .frame(height: 60)
    }
    _ = run(view)
    #expect(seen.isApproximately(Rect(x: 0, y: 20, width: 300, height: 60)))
}

@Test func geometryReaderFillsOfferedSpace() {
    let view = VStack(spacing: 0) {
        GeometryReader { _ in Color.black }
            .frame(height: 60)
        Color.white.frame(height: 40)
    }
    let (surface, _) = run(view)
    #expect(surface.fills[0].rect.isApproximately(Rect(x: 0, y: 0, width: 300, height: 60)))
    #expect(surface.fills[1].rect.isApproximately(Rect(x: 0, y: 60, width: 300, height: 40)))
}

// MARK: ForEach

@Test func forEachExpandsInOrder() {
    let view = VStack(spacing: 0) {
        ForEach(0..<3) { i in
            Color.black.frame(height: Double(10 * (i + 1)))
        }
    }
    let (surface, _) = run(view)
    #expect(surface.fills.map(\.rect.height) == [10, 20, 30])
    #expect(surface.fills.map(\.rect.y) == [0, 10, 30])
}

@Test func forEachOverArrayData() {
    let labels = ["a", "bb", "ccc"]
    let view = HStack(spacing: 0) {
        ForEach(labels) { Text($0, size: 10) }
    }
    let (surface, _) = run(view)
    #expect(surface.labels.map(\.string) == ["a", "bb", "ccc"])
}

// MARK: anchor / region

@Test func anchorExportsResolvedFrame() {
    let view = ZStack {
        Color.black
        Color.white.frame(width: 80, height: 50, alignment: .center)
            .anchor("screen")
    }
    let (_, result) = run(view)
    #expect(result.anchors["screen"]?.isApproximately(Rect(x: 110, y: 75, width: 80, height: 50)) == true)
}

@Test func regionCollectsHitTargetWithPayload() {
    let view = VStack(spacing: 0) {
        Color.black.frame(height: 100).region("top")
        Color.white.frame(height: 100).region("bottom")
    }
    let (_, result) = run(view)
    #expect(result.regions.count == 2)
    #expect(result.hit(Point(x: 10, y: 150), as: String.self) == "bottom")
    #expect(result.hit(Point(x: 10, y: 10), as: String.self) == "top")
}

@Test func onTapGestureCollectsHitTargetWithPayload() {
    let view = ZStack {
        Color.white
        Color.black
            .frame(width: 80, height: 50, alignment: .center)
            .onTapGesture("tap")
    }

    let (_, result) = run(view)
    #expect(result.regions.count == 1)
    #expect(result.hit(Point(x: 150, y: 100), as: String.self) == "tap")
}

@Test func onTapGesturePerformsClosureWhenHit() {
    var taps = 0
    let view = ZStack {
        Color.white
        Color.black
            .frame(width: 80, height: 50, alignment: .center)
            .onTapGesture { taps += 1 }
    }

    let (_, result) = run(view)
    #expect(result.tap(Point(x: 10, y: 10)) == false)
    #expect(taps == 0)
    #expect(result.tap(Point(x: 150, y: 100)) == true)
    #expect(taps == 1)
}

@Test func controlExportsSemanticMetadataWithResolvedFrame() {
    let view = Color.white
        .frame(width: 120, height: 48)
        .control(XControl(id: "play", label: "遊ぶ"))
    let result = LayoutHost(canvas: Size(width: 240, height: 120)).render(view, into: RecordingCanvas())

    #expect(result.controls.count == 1)
    #expect(result.controls[0].control.id == "play")
    #expect(result.controls[0].control.label == "遊ぶ")
    #expect(result.controls[0].control.scope == .content)
    #expect(result.controls[0].rect.size == Size(width: 120, height: 48))
}

@Test func anchorOnMultiNodeContentWrapsAndUnions() {
    let view = HStack(spacing: 0) {
        Color.black.frame(width: 40, height: 40)
        Color.white.frame(width: 60, height: 20)
    }
    .anchor("row")
    let (_, result) = run(view)
    #expect(result.anchors["row"]?.width == 100)
    #expect(result.anchors["row"]?.height == 40)
}
