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

private final class RecordingDelegate: XAppDelegate {
    var events: [String] = []

    func applicationDidLaunch(_ application: any XApplicationRuntimeProtocol) {
        events.append("launch")
    }

    func applicationDidBecomeActive(_ application: any XApplicationRuntimeProtocol) {
        events.append("active")
    }

    func applicationWillResignActive(_ application: any XApplicationRuntimeProtocol) {
        events.append("inactive")
    }

    func applicationDidEnterBackground(_ application: any XApplicationRuntimeProtocol) {
        events.append("background")
    }

    func applicationWillTerminate(_ application: any XApplicationRuntimeProtocol) {
        events.append("terminate")
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

@Test func applicationRuntimeForwardsLifecycleInOrder() {
    let renderer = RecordingRenderer()
    let delegate = RecordingDelegate()
    let runtime = XApplication.runtime(TestApp(), renderer: renderer, delegate: delegate)

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
