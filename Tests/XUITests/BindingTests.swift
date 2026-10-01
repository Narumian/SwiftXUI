import Testing
@testable import XUI

private actor BindingModel {
    var value = 0

    func setValue(_ value: Int) {
        self.value = value
    }
}

@Test func actorBindingReadsAndWritesAnActorValue() async {
    let model = BindingModel()
    let binding = ActorBinding<Int>(
        get: { await model.value },
        set: { await model.setValue($0) }
    )

    #expect(await binding.get() == 0)
    await binding.set(7)
    #expect(await binding.get() == 7)
}

@Test @XUIActor func bindingSetInvalidatesTheCurrentStore() async {
    let store = StateStore()
    var changes = 0
    store.onChange = { changes += 1 }

    let model = BindingModel()
    let binding = ActorBinding<Int>(
        get: { await model.value },
        set: { await model.setValue($0) }
    )

    await _XUIBindingContext.$store.withValue(store) {
        _ = await binding.get()
    }
    await binding.set(1)
    await Task.yield()

    #expect(changes == 1)
}
