import Testing
import XRender
import XUI
@testable import XUIHost

private final class RootProbe: @unchecked Sendable {
    var declarations = 0
    var paints = 0
    var text = ""
    var state: StateStore.Box<Bool>?
}

private struct ProbeContent: XView, _Stateful {
    let probe: RootProbe
    private var toggle: StateStore.Box<Bool>?

    init(probe: RootProbe) { self.probe = probe }

    mutating func _installState(id: StateIdentity, store: StateStore) {
        let box = store._xstateBox(id: id, name: "toggle") { false }
        toggle = box
        probe.state = box
    }

    var body: some XView {
        VStack {
            XUI.Text(toggle?.value == true ? "ON" : "OFF")
            TextField("Search", text: Binding(get: { probe.text }, set: { probe.text = $0 }), id: "search")
            DrawLayer { rect, context in
                probe.paints += 1
                context.canvas.fillRect(rect, color: .white)
            }.frame(width: 40, height: 40)
        }
    }
}

private struct ProbeApp: XApp {
    let probe: RootProbe
    let delegate = ProbeDelegate()
    var body: some XView {
        probe.declarations += 1
        return ProbeContent(probe: probe)
    }
}

private final class ProbeDelegate: XAppDelegate, Sendable {}

@Test @XUIActor
func retainedRootRepaintsAndInvalidatesForStateTextSizeAndExternalRevision() async {
    let probe = RootProbe()
    let session = XAppSession(ProbeApp(probe: probe))
    session.host.textFocus.keyboardPolicy = .never
    session.host.focusStore.selectedID = "search"
    let first = await session.render(time: 0, layoutRevision: 0)
    #expect(first.stats.layoutPasses == 1)
    let second = await session.render(time: 1, layoutRevision: 0)
    #expect(second.stats.layoutPasses == 0)
    #expect(probe.declarations == 1)
    #expect(probe.paints == 2)

    // A state write invalidates even when it did not arrive through host input.
    probe.state?.value = true
    #expect(await session.render(time: 2, layoutRevision: 0).stats.layoutPasses == 1)
    #expect(await session.render(time: 3, layoutRevision: 0).stats.layoutPasses == 0)

    session.host.textFocus.focus("search")
    _ = await session.render(time: 4, layoutRevision: 0)
    #expect(session.key(KeyEvent(.character("x"))))
    #expect(probe.text == "x")
    #expect(await session.render(time: 5, layoutRevision: 0).stats.layoutPasses == 1)
    #expect(await session.render(time: 6, layoutRevision: 0).stats.layoutPasses == 0)

    session.host.size = RenderSize(width: 500, height: 400)
    #expect(await session.render(time: 7, layoutRevision: 0).stats.layoutPasses == 1)
    #expect(await session.render(time: 8, layoutRevision: 0).stats.layoutPasses == 0)
    #expect(await session.render(time: 9, layoutRevision: 1).stats.layoutPasses == 1)
    #expect(await session.render(time: 10, layoutRevision: 1).stats.layoutPasses == 0)
}
