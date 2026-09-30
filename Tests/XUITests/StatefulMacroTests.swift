import Testing
@testable import XUI

/// `@Stateful` should produce the exact same behaviour as hand-writing
/// `_Stateful` conformance + `_installState` — this mirrors `EntranceOnce`
/// from `StatefulXViewTests.swift`, just with the macro generating both the
/// conformance and the install body from the `@XState` property.

@Stateful
private struct MacroEntranceOnce: XView {
    @XState private var spawned: Bool = false

    var body: some XView {
        Color(alreadyPlayed() ? .red : .black)
    }

    private func alreadyPlayed() -> Bool {
        defer { spawned = true }
        return spawned
    }
}

@Test @XUIActor func statefulMacroExpandsToTheMarkerConformance() async {
    #expect(MacroEntranceOnce() is any _Stateful)
}

@Test @XUIActor func statefulMacroWiredViewPersistsAcrossRenders() async {
    let store = StateStore()

    @XUIActor
    func fillColor() async -> XColorValue? {
        let surface = RecordingCanvas()
        await LayoutHost(canvas: Size(width: 100, height: 100)).render(MacroEntranceOnce(), into: surface, store: store)
        return surface.fills.first?.color
    }

    #expect(await fillColor() == .black)
    #expect(await fillColor() == .red)
}

@Stateful
private struct BindingProbe {
    @XState var value: Int = 0
}

private struct BindingModel {
    var value: Int = 0
}

@Stateful
private struct NestedBindingProbe {
    @XState var model: BindingModel = BindingModel()
}

@Test @XUIActor func xStateGeneratesABindingProjection() async {
    var probe = BindingProbe()
    let store = StateStore()
    probe._installState(id: .root, store: store)

    let binding = probe.$value
    #expect(binding.wrappedValue == 0)

    binding.wrappedValue = 7
    #expect(probe.value == 7)
}

@Test @XUIActor func bindingProjectsWritableKeyPaths() async {
    var probe = NestedBindingProbe()
    let store = StateStore()
    probe._installState(id: .root, store: store)

    let value = probe.$model.value
    value.wrappedValue = 11

    #expect(probe.model.value == 11)
}
