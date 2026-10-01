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
