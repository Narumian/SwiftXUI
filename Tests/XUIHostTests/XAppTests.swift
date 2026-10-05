import Testing
import XRender
import XUI
@testable import XUIHost

private struct TestApp: XApp {
    let delegate = TestDelegate()

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

private final class TestDelegate: XAppDelegate, Sendable {}

private final class RecordingDelegate: XAppDelegate, @unchecked Sendable {
    var events: [String] = []

    func applicationDidLaunch() {
        events.append("launch")
    }

    func applicationDidBecomeActive() {
        events.append("active")
    }

    func applicationWillResignActive() {
        events.append("inactive")
    }

    func applicationDidEnterBackground() {
        events.append("background")
    }

    func applicationWillTerminate() {
        events.append("terminate")
    }
}

private struct LifecycleApp: XApp {
    let delegate: RecordingDelegate

    var body: some XView {
        Color.red
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

@Test @XUIActor func appSessionUsesTheAppConfiguration() async {
    let session = XApplication.session(TestApp())
    let frame = await session.render(time: 4)

    #expect(frame.scene.authoringCanvas == RenderSize(width: 640, height: 360))
    #expect(frame.scene.background == RenderColor(0.1, 0.2, 0.3, 1))
    #expect(frame.scene.commands.count == 1)
}

@Test @XUIActor func appSessionKeepsOneHostAcrossFrames() async {
    let session = XApplication.session(TestApp())
    let firstHost = ObjectIdentifier(session.host)

    _ = await session.render(time: 1)
    _ = await session.render(time: 2)

    #expect(ObjectIdentifier(session.host) == firstHost)
}

@Test @XUIActor func appDriverCompilesAndForwardsEachFrame() async {
    let renderer = RecordingRenderer()
    let driver = XAppDriver(TestApp(), renderer: renderer)

    let compiled = await driver.frame(
        at: 4,
        framebuffer: RenderSize(width: 1280, height: 720)
    )
    let next = await driver.frame(at: 4.5, framebuffer: RenderSize(width: 1280, height: 720))

    #expect(renderer.frames == [compiled, next])
    #expect(renderer.times == [0, 0.5])
    #expect(compiled.draws.count == 1)
    #expect(compiled.shapeVertices.count == 36)
}

@Test @XUIActor func applicationRuntimeForwardsLifecycleInOrder() async {
    let renderer = RecordingRenderer()
    let delegate = RecordingDelegate()
    let runtime = XApplication.runtime(
        LifecycleApp(delegate: delegate),
        renderer: renderer
    )

    runtime.start()
    runtime.start()
    runtime.enterBackground()
    runtime.becomeActive()
    runtime.terminate()

    #expect(delegate.events == [
        "launch", "active", "inactive", "background", "active", "inactive", "terminate"
    ])
    #expect(!runtime.isRunning)
    #expect(!runtime.isActive)
}
