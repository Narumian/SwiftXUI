import Testing
@testable import XUI

@ObservableActor
private actor ObservableActorProbe {
    var count: Int = 0
}

@Test func observableActorGeneratesAnAsyncBinding() async {
    let probe = ObservableActorProbe()
    let binding = await probe.$count

    #expect(await binding.get() == 0)
    await binding.set(3)
    #expect(await probe.count == 3)
}
