import Dispatch
import XCTest
@testable import XCombine

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

final class XInboxTests: XCTestCase {
    func testDrainDeliversInArrivalOrderToEverySubscriber() {
        let inbox = XInbox<Int>()
        var a: [Int] = [], b: [Int] = []
        let ta = inbox.sink { a.append($0) }
        let tb = inbox.map { $0 * 10 }.sink { b.append($0) }
        for i in 1...5 { inbox.send(i) }
        XCTAssertEqual(a, [], "nothing is delivered until the owner drains")
        XCTAssertEqual(inbox.pendingCount, 5)
        XCTAssertEqual(inbox.drain(), 5)
        XCTAssertEqual(a, [1, 2, 3, 4, 5])
        XCTAssertEqual(b, [10, 20, 30, 40, 50])
        XCTAssertEqual(inbox.pendingCount, 0)
        XCTAssertEqual(inbox.drain(), 0)
        withExtendedLifetime((ta, tb)) {}
    }

    func testDrainRunsSubscribersOnTheDrainingThread() {
        let inbox = XInbox<Int>()
        let drainThread = Thread.current
        var wrongThread = false
        let token = inbox.sink { _ in if Thread.current != drainThread { wrongThread = true } }
        let producer = DispatchQueue(label: "producer")
        producer.sync { for i in 0..<10 { inbox.send(i) } }
        inbox.drain()
        XCTAssertFalse(wrongThread)
        withExtendedLifetime(token) {}
    }

    func testDropOldestKeepsTheNewestAndCounts() {
        let inbox = XInbox<Int>(overflow: .dropOldest(capacity: 3))
        var seen: [Int] = []
        let token = inbox.sink { seen.append($0) }
        for i in 1...10 { inbox.send(i) }
        XCTAssertEqual(inbox.pendingCount, 3)
        XCTAssertEqual(inbox.droppedCount, 7)
        inbox.drain()
        XCTAssertEqual(seen, [8, 9, 10])
        withExtendedLifetime(token) {}
    }

    func testDropOldestAcrossManyCompactions() {
        let inbox = XInbox<Int>(overflow: .dropOldest(capacity: 100))
        var seen: [Int] = []
        let token = inbox.sink { seen.append($0) }
        for i in 0..<10_000 { inbox.send(i) }
        inbox.drain()
        XCTAssertEqual(seen, Array(9_900..<10_000))
        XCTAssertEqual(inbox.droppedCount, 9_900)
        for i in 0..<3 { inbox.send(i) }
        seen.removeAll()
        inbox.drain()
        XCTAssertEqual(seen, [0, 1, 2], "the buffer is clean after a drain")
        withExtendedLifetime(token) {}
    }

    func testWakeFiresOncePerBurstNotPerValue() {
        let inbox = XInbox<Int>()
        let wakes = Counter()
        inbox.onWake { wakes.increment() }
        for i in 0..<100 { inbox.send(i) }
        XCTAssertEqual(wakes.count, 1)
        inbox.drain()
        inbox.send(1)
        XCTAssertEqual(wakes.count, 2, "an empty→non-empty transition wakes again")
        inbox.onWake(nil)
        inbox.drain()
        inbox.send(2)
        XCTAssertEqual(wakes.count, 2)
    }

    func testValueSentFromASubscriberWaitsForTheNextDrain() {
        let inbox = XInbox<Int>()
        let wakes = Counter()
        inbox.onWake { wakes.increment() }
        var seen: [Int] = []
        let token = inbox.sink { value in
            seen.append(value)
            if value == 1 { inbox.send(2) }
        }
        inbox.send(1)
        inbox.drain()
        XCTAssertEqual(seen, [1])
        XCTAssertEqual(wakes.count, 2, "the follow-up re-armed the wake")
        inbox.drain()
        XCTAssertEqual(seen, [1, 2])
        withExtendedLifetime(token) {}
    }

    func testDrainingFromInsideASubscriberDoesNotRecurse() {
        let inbox = XInbox<Int>()
        var seen: [Int] = []
        var inner = -1
        let token = inbox.sink { value in
            seen.append(value)
            inner = inbox.drain()
        }
        inbox.send(1); inbox.send(2)
        inbox.drain()
        XCTAssertEqual(seen, [1, 2])
        XCTAssertEqual(inner, 0)
        withExtendedLifetime(token) {}
    }

    func testCancelledSubscriberStopsReceiving() {
        let inbox = XInbox<Int>()
        var seen: [Int] = []
        let token = inbox.sink { seen.append($0) }
        inbox.send(1)
        inbox.drain()
        token.cancel()
        inbox.send(2)
        inbox.drain()
        XCTAssertEqual(seen, [1])
    }

    func testManyProducersKeepPerProducerOrderAndLoseNothing() {
        let inbox = XInbox<Int>()
        let producers = 8, perProducer = 20_000
        var lastSeen = [Int](repeating: -1, count: producers)
        var total = 0
        var outOfOrder = false
        let token = inbox.sink { value in
            let producer = value / perProducer, sequence = value % perProducer
            if sequence != lastSeen[producer] + 1 { outOfOrder = true }
            lastSeen[producer] = sequence
            total += 1
        }
        let done = DispatchGroup()
        for producer in 0..<producers {
            DispatchQueue.global().async(group: done) {
                for sequence in 0..<perProducer { inbox.send(producer * perProducer + sequence) }
            }
        }
        // Drain concurrently with the producers, as a real owner would.
        while done.wait(timeout: .now()) == .timedOut { inbox.drain() }
        inbox.drain()
        XCTAssertEqual(total, producers * perProducer)
        XCTAssertFalse(outOfOrder)
        withExtendedLifetime(token) {}
    }

    func testInboxCanDieWhileSubscribed() {
        weak var weakInbox: XInbox<Int>?
        var token: XAnyCancellable?
        do {
            let inbox = XInbox<Int>()
            weakInbox = inbox
            token = inbox.sink { _ in }
        }
        XCTAssertNil(weakInbox)
        token?.cancel()
    }
}
