import Foundation
import Testing
import XRender
import XUI
@testable import XUIHost

private final class DrawingProbe: @unchecked Sendable {
    var label = "Header"
    var fill = XColorValue.white
    var paints = 0
    var taps = 0
}

private struct DrawingApp: XApp {
    let probe: DrawingProbe
    let delegate = DrawingDelegate()

    var body: some XView {
        VStack {
            Text(probe.label, size: 12)
                .background { Color.gray }
                .border(.blue)
                .onTapGesture(id: "header", label: "Header") { probe.taps += 1 }
            DrawLayer { rect, context in
                probe.paints += 1
                context.canvas.fillRect(rect, color: probe.fill)
            }.frame(width: 40, height: 40)
        }
    }
}

private final class DrawingDelegate: XAppDelegate, Sendable {}

@Test @XUIActor
func staticDrawsReuseCommandsWhileLivePaintAndInputContinue() async throws {
    let probe = DrawingProbe()
    let session = XAppSession(DrawingApp(probe: probe))
    let first = await session.render(time: 0, layoutRevision: 0)
    let second = await session.render(time: 1, layoutRevision: 0)
    #expect(second.stats.layoutPasses == 0)
    #expect(second.stats.staticDrawHits == 3)
    #expect(second.stats.staticDrawMisses == 0)
    #expect(second.stats.measureCalls == 0)
    #expect(first.scene == second.scene)
    #expect(first.layout.tapGestures.first?.rect == second.layout.tapGestures.first?.rect)

    probe.fill = .red
    let third = await session.render(time: 2, layoutRevision: 0)
    #expect(third.stats.staticDrawHits == 3)
    #expect(first.scene.commands.dropLast() == third.scene.commands.dropLast())
    #expect(first.scene.commands.last != third.scene.commands.last)
    #expect(probe.paints == 3)
    let tap = try #require(third.layout.tapGestures.first { $0.id == "header" })
    tap.perform()
    #expect(probe.taps == 1)

    probe.label = "Changed"
    let changed = await session.render(time: 3, layoutRevision: 1)
    #expect(changed.stats.staticDrawMisses == 3)
    #expect(changed.scene.commands.contains { command in
        if case .text(let text) = command { return text.string == "Changed" }
        return false
    })
}

@Test
func staticDrawingCacheIncludesTransformClipLayerFrameAndEpoch() {
    var cache: AnyObject?
    let epoch = NSObject()
    let size = RenderSize(width: 200, height: 100)
    let frame = Rect(x: 3, y: 4, width: 20, height: 15)
    let first = SceneCanvas(size: size)
    first.drawingEpoch = epoch
    first.drawStatic(cache: &cache, frame: frame) { first.fillRect(frame, color: .red) }
    let replay = SceneCanvas(size: size)
    replay.drawingEpoch = epoch
    replay.drawStatic(cache: &cache, frame: frame) { Issue.record("Static draw ran again") }
    #expect(replay.staticDrawHits == 1)
    #expect(first.scene == replay.scene)

    let transformed = SceneCanvas(size: size)
    transformed.drawingEpoch = epoch
    transformed.pushTransform(.translation(x: 10, y: 20))
    transformed.pushClip(Rect(x: 0, y: 0, width: 50, height: 40))
    transformed.drawStatic(cache: &cache, frame: frame) { transformed.fillRect(frame, color: .red) }
    #expect(transformed.staticDrawMisses == 1)
    #expect(transformed.scene != first.scene)
    let expected = SceneCanvas(size: size)
    expected.pushTransform(.translation(x: 10, y: 20))
    expected.pushClip(Rect(x: 0, y: 0, width: 50, height: 40))
    expected.fillRect(frame, color: .red)
    #expect(transformed.scene == expected.scene)

    let newLayer = SceneCanvas(size: size, layer: .overlay)
    newLayer.drawingEpoch = epoch
    newLayer.drawStatic(cache: &cache, frame: frame) { newLayer.fillRect(frame, color: .red) }
    #expect(newLayer.staticDrawMisses == 1)
    let newFrame = Rect(x: 5, y: 4, width: 20, height: 15)
    newLayer.drawStatic(cache: &cache, frame: newFrame) { newLayer.fillRect(newFrame, color: .red) }
    #expect(newLayer.staticDrawMisses == 2)
    newLayer.drawingEpoch = NSObject()
    newLayer.drawStatic(cache: &cache, frame: newFrame) { newLayer.fillRect(newFrame, color: .red) }
    #expect(newLayer.staticDrawMisses == 3)
}
