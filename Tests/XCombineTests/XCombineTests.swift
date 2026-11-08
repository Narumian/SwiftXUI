import XCTest
@testable import XCombine

private struct TestError: Error, Equatable { let code: Int }

/// Collects what a subscriber saw, in order.
private final class Recorder<Value, Failure: Error> {
    var values: [Value] = []
    var completion: XSubscribers.Completion<Failure>?
    var finished: Bool { if case .finished? = completion { return true } else { return false } }
    var failure: Failure? { if case .failure(let e)? = completion { return e } else { return nil } }
}

private func capture<P: XPublisher>(_ publisher: P, into bag: inout [XAnyCancellable]) -> Recorder<P.Output, P.Failure> {
    let recorder = Recorder<P.Output, P.Failure>()
    publisher.sink(receiveCompletion: { recorder.completion = $0 }, receiveValue: { recorder.values.append($0) })
        .store(in: &bag)
    return recorder
}

final class XSubjectTests: XCTestCase {
    func testPassthroughDeliversInSubscriptionOrder() {
        let subject = XPassthroughSubject<Int, Never>()
        var order: [String] = []
        let a = subject.sink { order.append("a\($0)") }
        let b = subject.sink { order.append("b\($0)") }
        subject.send(1)
        subject.send(2)
        XCTAssertEqual(order, ["a1", "b1", "a2", "b2"])
        withExtendedLifetime((a, b)) {}
    }

    func testPassthroughDoesNotReplay() {
        let subject = XPassthroughSubject<Int, Never>()
        subject.send(1)
        var seen: [Int] = []
        let token = subject.sink { seen.append($0) }
        subject.send(2)
        XCTAssertEqual(seen, [2])
        withExtendedLifetime(token) {}
    }

    func testCurrentValueReplaysLatestToNewSubscriber() {
        let subject = XCurrentValueSubject<Int, Never>(1)
        subject.send(2)
        var seen: [Int] = []
        let token = subject.sink { seen.append($0) }
        subject.value = 3
        XCTAssertEqual(seen, [2, 3])
        XCTAssertEqual(subject.value, 3)
        withExtendedLifetime(token) {}
    }

    func testCancelStopsDeliveryAndDroppingTokenCancels() {
        let subject = XPassthroughSubject<Int, Never>()
        var seen: [Int] = []
        var token: XAnyCancellable? = subject.sink { seen.append($0) }
        subject.send(1)
        token = nil
        subject.send(2)
        XCTAssertEqual(seen, [1])
        XCTAssertEqual(subject.core.conduits.count, 0)
        _ = token
    }

    func testCancelTwiceIsHarmless() {
        let subject = XPassthroughSubject<Int, Never>()
        let token = subject.sink { _ in }
        token.cancel()
        token.cancel()
        subject.send(1)
    }

    func testCancelledSubscriberDoesNotSeeTheValueInFlight() {
        let subject = XPassthroughSubject<Int, Never>()
        var seenBySecond: [Int] = []
        var second: XAnyCancellable?
        let first = subject.sink { _ in second?.cancel() }
        second = subject.sink { seenBySecond.append($0) }
        subject.send(1)
        XCTAssertEqual(seenBySecond, [], "a subscriber cancelled mid-fan-out must not receive that value")
        withExtendedLifetime(first) {}
    }

    func testSubscribeDuringSendSeesOnlyLaterValues() {
        let subject = XPassthroughSubject<Int, Never>()
        var late: [Int] = []
        var lateToken: XAnyCancellable?
        let first = subject.sink { value in
            if value == 1, lateToken == nil { lateToken = subject.sink { late.append($0) } }
        }
        subject.send(1)
        subject.send(2)
        XCTAssertEqual(late, [2])
        withExtendedLifetime((first, lateToken)) {}
    }

    func testCompletionReachesEveryoneThenLaterSubscribersFinishImmediately() {
        let subject = XPassthroughSubject<Int, TestError>()
        var bag: [XAnyCancellable] = []
        let first = capture(subject, into: &bag)
        subject.send(1)
        subject.send(completion: .failure(TestError(code: 7)))
        subject.send(2)
        XCTAssertEqual(first.values, [1])
        XCTAssertEqual(first.failure, TestError(code: 7))
        let late = capture(subject, into: &bag)
        XCTAssertEqual(late.values, [])
        XCTAssertEqual(late.failure, TestError(code: 7))
    }

    func testSubjectCanDieWhileSubscribed() {
        weak var weakSubject: XPassthroughSubject<Int, Never>?
        var token: XAnyCancellable?
        do {
            let subject = XPassthroughSubject<Int, Never>()
            weakSubject = subject
            token = subject.sink { _ in }
        }
        XCTAssertNil(weakSubject)
        token?.cancel()
    }

    func testCancelledSubscriptionReleasesItsClosure() {
        final class Probe {}
        weak var weakProbe: Probe?
        let subject = XPassthroughSubject<Int, Never>()
        do {
            let probe = Probe()
            weakProbe = probe
            let token = subject.sink { _ in _ = probe }
            token.cancel()
        }
        XCTAssertNil(weakProbe)
    }

    func testVoidSend() {
        let subject = XPassthroughSubject<Void, Never>()
        var count = 0
        let token = subject.sink { count += 1 }
        subject.send()
        subject.send()
        XCTAssertEqual(count, 2)
        withExtendedLifetime(token) {}
    }
}

final class XOperatorTests: XCTestCase {
    func testMapFilterCompactMapChain() {
        let subject = XPassthroughSubject<Int, Never>()
        var bag: [XAnyCancellable] = []
        let result = capture(subject.map { $0 * 2 }.filter { $0 > 2 }.compactMap { $0 == 6 ? nil : "v\($0)" }, into: &bag)
        for i in 0...4 { subject.send(i) }
        XCTAssertEqual(result.values, ["v4", "v8"])
    }

    func testRemoveDuplicatesAndDropFirst() {
        let subject = XPassthroughSubject<Int, Never>()
        var bag: [XAnyCancellable] = []
        let result = capture(subject.removeDuplicates().dropFirst(), into: &bag)
        for value in [1, 1, 2, 2, 3, 1] { subject.send(value) }
        XCTAssertEqual(result.values, [2, 3, 1])
    }

    func testOperatorCancelPropagatesUpstream() {
        let subject = XPassthroughSubject<Int, Never>()
        let token = subject.map { $0 + 1 }.filter { _ in true }.sink { _ in }
        XCTAssertEqual(subject.core.conduits.count, 1)
        token.cancel()
        XCTAssertEqual(subject.core.conduits.count, 0)
    }

    func testFailureAndCompletionFlowThroughOperators() {
        let subject = XPassthroughSubject<Int, TestError>()
        var bag: [XAnyCancellable] = []
        let result = capture(subject.map { $0 + 1 }, into: &bag)
        subject.send(1)
        subject.send(completion: .finished)
        XCTAssertEqual(result.values, [2])
        XCTAssertTrue(result.finished)
    }

    func testJustEmptyFail() {
        var bag: [XAnyCancellable] = []
        let just = capture(XJust(5), into: &bag)
        XCTAssertEqual(just.values, [5]); XCTAssertTrue(just.finished)
        let empty = capture(XEmpty<Int, Never>(), into: &bag)
        XCTAssertEqual(empty.values, []); XCTAssertTrue(empty.finished)
        let fail = capture(XFail<Int, TestError>(error: TestError(code: 1)), into: &bag)
        XCTAssertEqual(fail.failure, TestError(code: 1))
        let never = capture(XEmpty<Int, Never>(completeImmediately: false), into: &bag)
        XCTAssertNil(never.completion)
    }

    func testEraseToAnyPublisher() {
        let subject = XCurrentValueSubject<Int, Never>(1)
        let erased = subject.map { $0 + 1 }.eraseToAnyPublisher()
        var bag: [XAnyCancellable] = []
        let result = capture(erased, into: &bag)
        subject.send(5)
        XCTAssertEqual(result.values, [2, 6])
        bag.removeAll()
        XCTAssertEqual(subject.core.conduits.count, 0)
    }
}

final class XCombiningTests: XCTestCase {
    func testCombineLatestEmitsOncePerSideAfterBothHaveValues() {
        let a = XPassthroughSubject<Int, Never>()
        let b = XPassthroughSubject<String, Never>()
        var bag: [XAnyCancellable] = []
        let result = capture(a.combineLatest(b), into: &bag)
        a.send(1)
        XCTAssertEqual(result.values.count, 0)
        b.send("x")
        a.send(2)
        b.send("y")
        XCTAssertEqual(result.values.map { "\($0.0)\($0.1)" }, ["1x", "2x", "2y"])
    }

    func testCombineLatestWithCurrentValueSubjectsStartsImmediately() {
        let a = XCurrentValueSubject<Int, Never>(1)
        let b = XCurrentValueSubject<Int, Never>(10)
        var bag: [XAnyCancellable] = []
        let result = capture(a.combineLatest(b) { $0 + $1 }, into: &bag)
        a.value = 2
        XCTAssertEqual(result.values, [11, 12])
    }

    func testCombineLatestFinishesWhenBothFinishAndFailsAtOnce() {
        let a = XPassthroughSubject<Int, TestError>()
        let b = XPassthroughSubject<Int, TestError>()
        var bag: [XAnyCancellable] = []
        let result = capture(a.combineLatest(b), into: &bag)
        a.send(completion: .finished)
        XCTAssertNil(result.completion)
        b.send(completion: .finished)
        XCTAssertTrue(result.finished)

        let c = XPassthroughSubject<Int, TestError>()
        let d = XPassthroughSubject<Int, TestError>()
        let failing = capture(c.combineLatest(d), into: &bag)
        c.send(completion: .failure(TestError(code: 3)))
        XCTAssertEqual(failing.failure, TestError(code: 3))
        XCTAssertEqual(d.core.conduits.count, 0, "the other side is cancelled on failure")
    }

    func testCombineLatestCancelReleasesBothSides() {
        let a = XPassthroughSubject<Int, Never>()
        let b = XPassthroughSubject<Int, Never>()
        let token = a.combineLatest(b).sink { _ in }
        token.cancel()
        XCTAssertEqual(a.core.conduits.count, 0)
        XCTAssertEqual(b.core.conduits.count, 0)
    }

    func testMergeInterleavesAndFinishesWhenAllFinish() {
        let a = XPassthroughSubject<Int, Never>()
        let b = XPassthroughSubject<Int, Never>()
        var bag: [XAnyCancellable] = []
        let result = capture(a.merge(with: b), into: &bag)
        a.send(1); b.send(2); a.send(3)
        a.send(completion: .finished)
        XCTAssertNil(result.completion)
        b.send(completion: .finished)
        XCTAssertEqual(result.values, [1, 2, 3])
        XCTAssertTrue(result.finished)
    }

    func testMergeManyAndEmpty() {
        let subjects = (0..<3).map { _ in XPassthroughSubject<Int, Never>() }
        var bag: [XAnyCancellable] = []
        let result = capture(XPublishers.MergeMany(subjects), into: &bag)
        subjects[2].send(9); subjects[0].send(4)
        XCTAssertEqual(result.values, [9, 4])
        let empty = capture(XPublishers.MergeMany<XPassthroughSubject<Int, Never>>([]), into: &bag)
        XCTAssertTrue(empty.finished)
        bag.removeAll()
        XCTAssertTrue(subjects.allSatisfy { $0.core.conduits.isEmpty })
    }

    func testMergeFailureCancelsTheRest() {
        let a = XPassthroughSubject<Int, TestError>()
        let b = XPassthroughSubject<Int, TestError>()
        var bag: [XAnyCancellable] = []
        let result = capture(a.merge(with: b), into: &bag)
        a.send(completion: .failure(TestError(code: 2)))
        XCTAssertEqual(result.failure, TestError(code: 2))
        XCTAssertEqual(b.core.conduits.count, 0)
    }
}

final class XSwitchToLatestTests: XCTestCase {
    func testFollowsOnlyTheLatestInnerAndCancelsTheOld() {
        let outer = XPassthroughSubject<XPassthroughSubject<Int, Never>, Never>()
        let first = XPassthroughSubject<Int, Never>()
        let second = XPassthroughSubject<Int, Never>()
        var bag: [XAnyCancellable] = []
        let result = capture(outer.switchToLatest(), into: &bag)
        outer.send(first)
        first.send(1)
        outer.send(second)
        first.send(99)
        second.send(2)
        XCTAssertEqual(result.values, [1, 2])
        XCTAssertEqual(first.core.conduits.count, 0)
        XCTAssertEqual(second.core.conduits.count, 1)
    }

    func testSwitchingInsideAnInnerHandlerDropsTheStaleValue() {
        // The old inner is mid-fan-out when the outer switches away from it: the value that
        // was already in flight to the switch must not leak through after the switch.
        let outer = XPassthroughSubject<XPassthroughSubject<Int, Never>, Never>()
        let first = XPassthroughSubject<Int, Never>()
        let second = XPassthroughSubject<Int, Never>()
        var bag: [XAnyCancellable] = []
        let ahead = first.sink { _ in outer.send(second) }   // runs before the switch's own subscription
        let result = capture(outer.switchToLatest(), into: &bag)
        outer.send(first)
        first.send(1)
        XCTAssertEqual(result.values, [], "the switch moved to `second` before it saw `first`'s value")
        withExtendedLifetime(ahead) {}
    }

    func testFinishesOnlyWhenOuterAndCurrentInnerAreDone() {
        let outer = XPassthroughSubject<XPassthroughSubject<Int, Never>, Never>()
        let inner = XPassthroughSubject<Int, Never>()
        var bag: [XAnyCancellable] = []
        let result = capture(outer.switchToLatest(), into: &bag)
        outer.send(inner)
        outer.send(completion: .finished)
        XCTAssertNil(result.completion)
        inner.send(completion: .finished)
        XCTAssertTrue(result.finished)
    }

    func testInnerFailureFailsTheSwitch() {
        let outer = XPassthroughSubject<XPassthroughSubject<Int, TestError>, TestError>()
        let inner = XPassthroughSubject<Int, TestError>()
        var bag: [XAnyCancellable] = []
        let result = capture(outer.switchToLatest(), into: &bag)
        outer.send(inner)
        inner.send(completion: .failure(TestError(code: 5)))
        XCTAssertEqual(result.failure, TestError(code: 5))
        XCTAssertEqual(outer.core.conduits.count, 0)
    }

    func testModeStyleSwitchingWithJustAndEmpty() {
        let mode = XCurrentValueSubject<Bool, Never>(false)
        let live = XCurrentValueSubject<Int, Never>(7)
        var bag: [XAnyCancellable] = []
        let result = capture(
            mode.map { isLive -> XAnyPublisher<Int, Never> in isLive ? live.eraseToAnyPublisher() : XJust(0).eraseToAnyPublisher() }
                .switchToLatest(),
            into: &bag)
        mode.value = true
        live.value = 8
        mode.value = false
        live.value = 9
        XCTAssertEqual(result.values, [0, 7, 8, 0])
    }

    func testCancelReleasesOuterAndInner() {
        let outer = XPassthroughSubject<XPassthroughSubject<Int, Never>, Never>()
        let inner = XPassthroughSubject<Int, Never>()
        let token = outer.switchToLatest().sink { _ in }
        outer.send(inner)
        token.cancel()
        XCTAssertEqual(outer.core.conduits.count, 0)
        XCTAssertEqual(inner.core.conduits.count, 0)
    }
}
