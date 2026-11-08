import Dispatch
import XCTest
@testable import XCombine

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Double] = []
    func add(_ v: Double) { lock.lock(); items.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return items }
    var count: Int { values.count }
}

/// A manual clock, so the values can be checked exactly.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = 100.0
    func read() -> Double { lock.lock(); defer { lock.unlock() }; t += 0.5; return t }
}

final class XTimerTests: XCTestCase {
    private let queue = DispatchQueue(label: "XTimerTests")

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        return condition()
    }

    func testFiresRepeatedlyWithTheClockValueAndStopsOnCancel() {
        let clock = Clock()
        let timer = XTimer(every: 0.01, queue: queue, now: { clock.read() })
        let log = Log()
        XCTAssertFalse(timer.isRunning)
        let token = timer.sink { log.add($0) }
        XCTAssertTrue(timer.isRunning)
        XCTAssertTrue(waitUntil { log.count >= 3 })
        XCTAssertEqual(Array(log.values.prefix(3)), [100.5, 101, 101.5], "one clock read per firing, in order")
        token.cancel()
        XCTAssertFalse(timer.isRunning)
        let seen = log.count
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertEqual(log.count, seen, "nothing after cancel")
    }

    func testSubscribersShareOneTimerAndItStopsWithTheLast() {
        let timer = XTimer(every: 0.01, queue: queue)
        let a = Log(), b = Log()
        let ta = timer.sink { a.add($0) }
        let tb = timer.map { $0 * 2 }.sink { b.add($0) }
        XCTAssertTrue(waitUntil { a.count >= 2 && b.count >= 2 })
        ta.cancel()
        XCTAssertTrue(timer.isRunning, "one subscriber is still listening")
        let aSeen = a.count, bSeen = b.count
        XCTAssertTrue(waitUntil { b.count >= bSeen + 2 })
        XCTAssertEqual(a.count, aSeen)
        tb.cancel()
        XCTAssertFalse(timer.isRunning)
    }

    func testSubscribingAgainRestartsIt() {
        let timer = XTimer.publish(every: 0.01, queue: queue)
        let first = Log()
        let t1 = timer.sink { first.add($0) }
        XCTAssertTrue(waitUntil { first.count >= 1 })
        t1.cancel()
        XCTAssertFalse(timer.isRunning)
        let second = Log()
        let t2 = timer.sink { second.add($0) }
        XCTAssertTrue(waitUntil { second.count >= 2 })
        XCTAssertGreaterThan(second.values[0], first.values[0], "the clock is monotonic across restarts")
        t2.cancel()
    }

    func testDroppingTheTokenStopsTheTimer() {
        let timer = XTimer(every: 0.01, queue: queue)
        var token: XAnyCancellable? = timer.sink { _ in }
        XCTAssertTrue(timer.isRunning)
        token = nil
        XCTAssertFalse(timer.isRunning)
        withExtendedLifetime(token) {}
    }

    func testCancelFromInsideADeliveryAndBadIntervals() {
        let timer = XTimer(every: 0.005, queue: queue)
        let log = Log()
        var token: XAnyCancellable?
        token = timer.sink { time in
            log.add(time)
            token?.cancel()
        }
        XCTAssertTrue(waitUntil { !timer.isRunning })
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(log.count, 1, "a cancel inside a delivery ends it at once")
        XCTAssertEqual(XTimer(every: .nan).interval, 1)
        XCTAssertEqual(XTimer(every: -3).interval, 1e-6)
        XCTAssertEqual(XTimer(every: 0.25).interval, 0.25)
    }
}
