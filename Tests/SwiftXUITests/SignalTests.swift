import Testing
@testable import SwiftXUI

@Test func sendDeliversToEverySubscriberInOrder() {
    let signal = Signal<Int>()
    var received: [String] = []
    let a = signal.subscribe { received.append("a:\($0)") }
    let b = signal.subscribe { received.append("b:\($0)") }
    _ = (a, b)

    signal.send(1)

    #expect(received == ["a:1", "b:1"])
}

@Test func cancellingStopsDelivery() {
    let signal = Signal<Int>()
    var received: [Int] = []
    let subscription = signal.subscribe { received.append($0) }

    signal.send(1)
    subscription.cancel()
    signal.send(2)

    #expect(received == [1])
}

@Test func droppingTheSubscriptionTokenAlsoStopsDelivery() {
    let signal = Signal<Int>()
    var received: [Int] = []
    do {
        let subscription = signal.subscribe { received.append($0) }
        _ = subscription
        signal.send(1)
    }
    signal.send(2)

    #expect(received == [1])
}

@Test func voidSignalHasAnArgumentlessSend() {
    let signal = Signal<Void>()
    var count = 0
    let subscription = signal.subscribe { count += 1 }
    _ = subscription

    signal.send()

    #expect(count == 1)
}

@Test func bufferedSignalQueuesUntilDrainedOntoASignal() {
    let bridge = BufferedSignal<Int>()
    let signal = Signal<Int>()
    var received: [Int] = []
    let subscription = signal.subscribe { received.append($0) }
    _ = subscription

    bridge.send(1)
    bridge.send(2)
    #expect(received.isEmpty, "nothing should be delivered before draining")

    bridge.drain(into: signal)
    #expect(received == [1, 2])
}

@Test func bufferedSignalDrainIsEmptyAfterFlushing() {
    let bridge = BufferedSignal<Int>()
    let signal = Signal<Int>()
    var received: [Int] = []
    let subscription = signal.subscribe { received.append($0) }
    _ = subscription

    bridge.send(1)
    bridge.drain(into: signal)
    bridge.drain(into: signal)

    #expect(received == [1])
}

@Test func bufferedSignalAcceptsSendsFromAnotherThread() async {
    let bridge = BufferedSignal<Int>()
    let signal = Signal<Int>()
    var received: [Int] = []
    let subscription = signal.subscribe { received.append($0) }
    _ = subscription

    await withTaskGroup(of: Void.self) { group in
        for value in 1...10 {
            group.addTask { bridge.send(value) }
        }
    }

    bridge.drain(into: signal)
    #expect(received.sorted() == Array(1...10))
}

@Test func bufferedSignalDrainWithClosureConsumesInOrderAndEmptiesTheQueue() {
    let bridge = BufferedSignal<Int>()
    bridge.send(1)
    bridge.send(2)

    var consumed: [Int] = []
    bridge.drain { consumed.append($0) }
    #expect(consumed == [1, 2])

    consumed.removeAll()
    bridge.drain { consumed.append($0) }
    #expect(consumed.isEmpty, "already drained — nothing new was sent")
}
