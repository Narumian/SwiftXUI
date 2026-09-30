import Testing
@testable import XUI

/// `.trigger` is `.onReceive` plus a self-contained, frame-counted pulse —
/// these tests drive it purely through repeated `lower` walks (no real
/// clock), the same way `OnReceiveTests` drives the subscription lifecycle.
/// Peak scale is read back off the recorded fill's post-transform width,
/// since `RecordingCanvas` doesn't expose its transform stack directly.

@XUIActor
private func fillWidth(_ signal: Signal<Int>, store: StateStore) async -> Double {
    let view = Color(.black).trigger(signal, on: 1, peakScale: 2, frames: 4)
    let canvas = RecordingCanvas()
    _ = await LayoutHost(canvas: Size(width: 10, height: 10)).render(view, into: canvas, store: store)
    return canvas.fills.last!.rect.width
}

@Test @XUIActor func triggerStaysAtRestUntilAMatchingValueArrives() async {
    let signal = Signal<Int>()
    let store = StateStore()
    let rest = await fillWidth(signal, store: store)
    #expect(await fillWidth(signal, store: store) == rest, "no trigger fired — width should be stable")
}

@Test @XUIActor func triggerPulsesForExactlyFramesWalksThenSettles() async {
    let signal = Signal<Int>()
    let store = StateStore()

    let rest = await fillWidth(signal, store: store)

    signal.send(1)
    let peak = await fillWidth(signal, store: store)
    #expect(peak > rest * 1.9, "first walk after a match should be at (or essentially at) peak scale")

    let mid = await fillWidth(signal, store: store)
    #expect(mid < peak, "scale should be settling back down on later walks")

    for _ in 0..<10 { _ = await fillWidth(signal, store: store) }
    #expect(await fillWidth(signal, store: store) == rest, "should be fully at rest well after `frames` walks have passed")
}

@Test @XUIActor func triggerIgnoresNonMatchingValues() async {
    let signal = Signal<Int>()
    let store = StateStore()
    let rest = await fillWidth(signal, store: store)

    signal.send(2)
    #expect(await fillWidth(signal, store: store) == rest)
}
