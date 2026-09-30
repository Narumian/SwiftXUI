import Testing
import XRender
import XUI
@testable import XUIHost

private struct TestApp: XApp {
    var body: some XView {
        Color.red
    }

    var configuration: XAppConfiguration {
        XAppConfiguration(
            size: RenderSize(width: 640, height: 360),
            background: RenderColor(0.1, 0.2, 0.3, 1)
        )
    }
}

private final class RecordingRenderer: XRenderer {
    var frames: [CompiledFrame] = []
    var times: [Float] = []

    func render(_ frame: CompiledFrame, time: Float) {
        frames.append(frame)
        times.append(time)
    }
}

@Test func appSessionUsesTheAppConfiguration() {
    let session = XApplication.session(TestApp())
    let frame = session.render(time: 4)

    #expect(frame.scene.authoringCanvas == RenderSize(width: 640, height: 360))
    #expect(frame.scene.background == RenderColor(0.1, 0.2, 0.3, 1))
    #expect(frame.scene.commands.count == 1)
}

@Test func appSessionKeepsOneHostAcrossFrames() {
    let session = XApplication.session(TestApp())
    let firstHost = ObjectIdentifier(session.host)

    _ = session.render(time: 1)
    _ = session.render(time: 2)

    #expect(ObjectIdentifier(session.host) == firstHost)
}

@Test func appDriverCompilesAndForwardsEachFrame() {
    let renderer = RecordingRenderer()
    let driver = XAppDriver(TestApp(), renderer: renderer)

    let compiled = driver.frame(
        at: 4,
        framebuffer: RenderSize(width: 1280, height: 720)
    )

    #expect(renderer.frames == [compiled])
    #expect(renderer.times == [4])
    #expect(compiled.draws.count == 1)
    #expect(compiled.shapeVertices.count == 36)
}
