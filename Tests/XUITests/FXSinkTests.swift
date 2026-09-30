import Testing
@testable import XUI

/// `.fx(signal:anchor:)` subscribes once (identity-keyed, like `.onReceive`)
/// but defers applying anything received until this node's own `draw` call,
/// using whatever interpreter the app registered via `environment.fxApply`
/// — never a closure at the `.fx()` call site itself.
///
/// As in real usage, the subscription must already exist (i.e. this node
/// must already have been walked once) before `signal.send` is called —
/// `battleBody` is always walked at least once before any beat can fire, so
/// tests render once to install the subscription, then send, then render
/// again to observe delivery, reusing the same `StateStore` throughout
/// (a fresh store per call, like `LayoutHost`'s default, would never
/// remember the subscription across calls).

private struct TestFX: FX, _PrimitiveFX {
    typealias Body = Never
    let tag: String
}

@XUIActor
private func render(_ view: some XView, store: StateStore, environment: EnvironmentValues = EnvironmentValues()) async {
    let canvas = RecordingCanvas()
    _ = await LayoutHost(canvas: Size(width: 100, height: 100), environment: environment)
        .render(view, into: canvas, store: store)
}

@Test @XUIActor func fxDoesNothingWhenNothingWasSent() async {
    let store = StateStore()
    let signal = Signal<any FX>()
    var received: [(String, Point)] = []
    var env = EnvironmentValues()
    env.fxApply = { value, p in received.append(((value as! TestFX).tag, p)) }

    await render(Color(.black).fx(signal), store: store, environment: env)
    await render(Color(.black).fx(signal), store: store, environment: env)

    #expect(received.isEmpty)
}

@Test @XUIActor func fxDeliversAtThisFramesResolvedRectWithTheRegisteredAnchor() async {
    let store = StateStore()
    let signal = Signal<any FX>()
    var received: [(String, Point)] = []
    var env = EnvironmentValues()
    env.fxApply = { value, p in received.append(((value as! TestFX).tag, p)) }
    let view = Color(.black).frame(width: 40, height: 20).fx(signal, anchor: .topLeading)

    await render(view, store: store, environment: env) // installs the subscription
    signal.send(TestFX(tag: "pop"))
    await render(view, store: store, environment: env) // draws with this frame's rect, applies

    #expect(received.count == 1)
    #expect(received[0].0 == "pop")
    #expect(received[0].1 == Point(x: 0, y: 0), "topLeading of a 40x20 rect at the origin")
}

@Test @XUIActor func fxAtCenterUsesTheRectMidpoint() async {
    let store = StateStore()
    let signal = Signal<any FX>()
    var received: [Point] = []
    var env = EnvironmentValues()
    env.fxApply = { _, p in received.append(p) }
    let view = Color(.black).frame(width: 40, height: 20).fx(signal)

    await render(view, store: store, environment: env)
    signal.send(TestFX(tag: "spray"))
    await render(view, store: store, environment: env)

    #expect(received == [Point(x: 20, y: 10)])
}

@Test @XUIActor func fxDoesNothingWhenNoInterpreterIsRegistered() async {
    let store = StateStore()
    let signal = Signal<any FX>()
    let view = Color(.black).fx(signal)

    await render(view, store: store) // no fxApply set
    signal.send(TestFX(tag: "pop"))
    await render(view, store: store) // must not crash, must silently drop
}

@Test @XUIActor func fxBufferIsDrainedOncePerDraw() async {
    let store = StateStore()
    let signal = Signal<any FX>()
    var received: [String] = []
    var env = EnvironmentValues()
    env.fxApply = { value, _ in received.append((value as! TestFX).tag) }
    let view = Color(.black).fx(signal)

    await render(view, store: store, environment: env)
    signal.send(TestFX(tag: "a"))
    signal.send(TestFX(tag: "b"))
    await render(view, store: store, environment: env)
    #expect(received == ["a", "b"])

    received.removeAll()
    await render(view, store: store, environment: env)
    #expect(received.isEmpty, "already drained — nothing new was sent")
}

@Test @XUIActor func delayedLeafStartsOnlyOnceItsTimeArrives() async {
    struct Late: FX {
        var body: some FX { TestFX(tag: "late").delay(0.5) }
    }
    let store = StateStore()
    let signal = Signal<any FX>()
    var received: [String] = []
    func env(_ t: Double) -> EnvironmentValues {
        var e = EnvironmentValues()
        e.fxTime = t
        e.fxApply = { v, _ in received.append((v as! TestFX).tag) }
        return e
    }
    let view = Color(.black).fx(signal)

    await render(view, store: store, environment: env(0))
    signal.send(Late())
    await render(view, store: store, environment: env(0.1))
    #expect(received.isEmpty)
    await render(view, store: store, environment: env(0.4))
    #expect(received.isEmpty)
    await render(view, store: store, environment: env(0.7))
    #expect(received == ["late"])
    await render(view, store: store, environment: env(1.0))
    #expect(received == ["late"], "released once")
}

@Test @XUIActor func nestedDelaysAdd() async {
    let leaf = ScheduledFX(ScheduledFX(TestFX(tag: "x"), delay: 0.2), delay: 0.3)
    #expect(abs(leaf.delay - 0.5) < 1e-9)
    #expect((leaf.leaf as? TestFX)?.tag == "x")
}

@Test @XUIActor func delayedVisualStartsAtItsScheduledTimeNotTheFrameThatNoticed() async {
    final class Probe: FXPlayback {
        var finished = false
        func step(now: Double) {}
        func draw(in rect: Rect, context: RenderContext) {}
    }
    struct Leaf: FX, _PrimitiveFX, VFX {
        typealias Body = Never
        let onStart: (Double) -> Void
        func makePlayback(at point: Point, startedAt: Double) -> any FXPlayback {
            onStart(startedAt)
            return Probe()
        }
    }
    let store = StateStore()
    let signal = Signal<any FX>()
    var started: [Double] = []
    let view = Color(.black).fx(signal)
    func frame(_ t: Double) async {
        var e = EnvironmentValues()
        e.fxTime = t
        await render(view, store: store, environment: e)
    }
    await frame(0)
    signal.send(Leaf { started.append($0) }.delay(0.5))
    await frame(0.1)
    await frame(0.9) // a late frame
    #expect(started.count == 1)
    #expect(abs(started[0] - 0.6) < 1e-9, "due at 0.1 + 0.5, not 0.9")
}
