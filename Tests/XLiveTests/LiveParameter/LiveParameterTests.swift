import XCTest
import XLive
import XCombine

// MARK: - A host to test against

private final class HookedSubscription: XSubscription {
    private let inner: any XSubscription
    private var onCancel: (() -> Void)?
    init(_ inner: any XSubscription, onCancel: @escaping () -> Void) { self.inner = inner; self.onCancel = onCancel }
    func cancel() {
        guard let hook = onCancel else { return }
        onCancel = nil
        inner.cancel()
        hook()
    }
}

private struct HookedSubscriber<S: XSubscriber>: XSubscriber {
    let downstream: S
    let onCancel: () -> Void
    func receive(subscription: any XSubscription) { downstream.receive(subscription: HookedSubscription(subscription, onCancel: onCancel)) }
    func receive(_ input: S.Input) { downstream.receive(input) }
    func receive(completion: XSubscribers.Completion<S.Failure>) { downstream.receive(completion: completion) }
}

/// A subject that knows how many subscribers it has right now.
private final class Tracked<Output>: XPublisher {
    typealias Failure = Never
    let subject = XPassthroughSubject<Output, Never>()
    private(set) var active = 0
    private(set) var total = 0
    func send(_ value: Output) { subject.send(value) }
    func receive<S: XSubscriber>(subscriber: S) where S.Input == Output, S.Failure == Never {
        active += 1; total += 1
        subject.receive(subscriber: HookedSubscriber(downstream: subscriber, onCancel: { [self] in active -= 1 }))
    }
}

private final class Host: LiveParameterEnvironment {
    let clockSource = Tracked<LiveClockTick>()
    let midiSource = Tracked<MIDIMessage>()
    var sources: [LiveSourceDescriptor: Tracked<Double>] = [:]
    var registry: [LiveObjectID: LiveParameter] = [:]
    var midiTakeover: LiveTakeoverMode = .jump

    var clock: XAnyPublisher<LiveClockTick, Never> { clockSource.eraseToAnyPublisher() }
    var midi: XAnyPublisher<MIDIMessage, Never> { midiSource.eraseToAnyPublisher() }
    func publisher(for source: LiveSourceDescriptor) -> XAnyPublisher<Double, Never>? { sources[source]?.eraseToAnyPublisher() }
    func parameter(withID id: LiveObjectID) -> LiveParameter? { registry[id] }

    func step(_ seconds: Double, bpm: Double? = nil) { clockSource.send(LiveClockTick(deltaTime: seconds, bpm: bpm)) }
}

private final class Recorder<T>: @unchecked Sendable {
    var values: [T] = []
}

// MARK: - Tests

final class LiveParameterTests: XCTestCase {
    private func state(range: ClosedRange<Double> = 0...10, value: Double = 0, id: String = "p") throws -> LiveParameterState {
        try LiveParameterState(id: LiveObjectID(rawValue: id), label: id, value: value, mapping: LiveValueMapping(range: range))
    }

    func testAnIdleParameterListensToNothing() throws {
        let host = Host()
        let p = LiveParameter(state: try state(), environment: host)
        XCTAssertEqual(host.clockSource.active, 0, "no automation, nothing to time")
        XCTAssertEqual(host.midiSource.active, 0, "no address and not learning, nothing to hear")
        XCTAssertEqual(p.value, 0)
        host.step(1)
        XCTAssertEqual(p.value, 0)
    }

    func testMIDIIsHeardOnlyWhileAnAddressIsAssignedOrLearning() throws {
        let host = Host()
        let p = LiveParameter(state: try state(), environment: host)
        p.toggleLearning()
        XCTAssertEqual(host.midiSource.active, 1)
        host.midiSource.send(.controlChange(channel: 0, controller: 7, value: 127))
        XCTAssertEqual(p.state.midiAddresses.count, 1, "learned from the first message")
        XCTAssertEqual(host.midiSource.active, 1, "and keeps listening for its address")
        host.midiSource.send(.controlChange(channel: 0, controller: 7, value: 127))
        XCTAssertEqual(p.value, 10)

        p.edit { $0.setSource(.lfo); $0.setAutomation(on: true) }
        XCTAssertEqual(host.midiSource.active, 0, "automation ignores MIDI, so it stops listening")
        host.midiSource.send(.controlChange(channel: 0, controller: 7, value: 0))
        XCTAssertEqual(p.value, 10)

        let q = LiveParameter(state: try state(id: "q"), environment: host)
        q.toggleLearning()
        XCTAssertEqual(host.midiSource.active, 1)
        q.toggleLearning()
        XCTAssertEqual(host.midiSource.active, 0, "stopped learning with no address: unsubscribed again")
    }

    func testAutomationSubscribesToTheClockAndPublishesTheValue() throws {
        let host = Host()
        let p = LiveParameter(state: try state(), environment: host)
        let seen = Recorder<Double>()
        let token = p.valuePublisher.sink { seen.values.append($0) }
        XCTAssertEqual(seen.values, [0], "the current value first")

        p.edit {
            $0.setSource(.lfo); $0.setLFO(try! LiveLFO(period: .seconds(4))); $0.setAutomation(on: true)
        }
        XCTAssertEqual(host.clockSource.active, 1)
        host.step(0)
        XCTAssertEqual(p.value, 5, accuracy: 1e-9)
        host.step(1)
        XCTAssertEqual(p.value, 10, accuracy: 1e-9)
        XCTAssertEqual(seen.values.count, 3)
        host.step(0)
        XCTAssertEqual(seen.values.count, 3, "an unchanged value is not published again")

        p.toggleAutomation()
        host.step(1)    // the smoothed value catches up
        host.step(1)
        XCTAssertEqual(host.clockSource.active, 0, "off and settled: the clock is released")
        host.step(1)
        XCTAssertEqual(p.value, 10)
        withExtendedLifetime(token) {}
    }

    func testSettingByHandListensToTheClockOnlyUntilTheSmoothingSettles() throws {
        let host = Host()
        let p = LiveParameter(state: try state(range: 0...1), environment: host)
        p.setNormalizedManualValue(1)
        XCTAssertEqual(host.clockSource.active, 1)
        XCTAssertEqual(p.state.smoothedValue, 0)
        host.step(1.0 / 60)
        XCTAssertEqual(p.state.smoothedValue, 0.2, accuracy: 1e-9)
        host.step(1)
        XCTAssertEqual(p.state.smoothedValue, 1)
        XCTAssertEqual(host.clockSource.active, 0)
        XCTAssertEqual(host.clockSource.total, 1)
    }

    func testTheSourceIsSubscribedOnlyWhileAutomatedAndFollowsAChange() throws {
        let host = Host()
        let audio = Tracked<Double>(), motion = Tracked<Double>()
        host.sources = [.audio(.low): audio, .motion(.pitch): motion]
        let p = LiveParameter(state: try state(range: 0...1), environment: host)
        p.edit { $0.setSource(.audio(.low)) }
        XCTAssertEqual(audio.active, 0, "a source alone does not subscribe")
        p.toggleAutomation()
        XCTAssertEqual(audio.active, 1)
        audio.send(1)
        host.step(100)
        XCTAssertEqual(p.value, 1, accuracy: 1e-6)

        p.edit { $0.setSource(.motion(.pitch)) }
        XCTAssertEqual(audio.active, 0); XCTAssertEqual(motion.active, 1)
        motion.send(0.25)
        host.step(0.01)
        XCTAssertEqual(p.value, 0.25, accuracy: 1e-9)

        p.toggleAutomation()
        XCTAssertEqual(motion.active, 0)
        p.edit { $0.setSource(.gamepad(id: "none")); $0.setAutomation(on: true) }   // the host has no such source
        host.step(0.01)
        XCTAssertEqual(p.value, 0.25, "no signal holds")
    }

    func testPaceAndPulseWidthAreReadFromReferencedParameters() throws {
        let host = Host()
        let pace = LiveParameter(state: try state(range: 0...4, value: 2, id: "pace"), environment: host)
        host.registry[pace.id] = pace
        let p = LiveParameter(state: try state(), environment: host)
        p.edit {
            $0.setSource(.lfo); $0.setAutomation(on: true)
            $0.setLFO(try! LiveLFO(period: .seconds(4))); $0.setWave(LiveWave(shape: .saw))
            $0.setPaceReference(pace.id)
        }
        host.step(1)
        XCTAssertEqual(p.value, 5, accuracy: 1e-9, "a quarter cycle at pace 1, half at pace 2")
        pace.setManualValue(0)
        host.step(1)
        XCTAssertEqual(p.value, 5, accuracy: 1e-9, "pace 0 holds the phase")
    }

    func testMIDIComesThroughTheEnvironment() throws {
        let host = Host()
        let p = LiveParameter(state: try state(), environment: host)
        let seen = Recorder<Double>()
        let token = p.valuePublisher.sink { seen.values.append($0) }
        p.toggleLearning()
        XCTAssertEqual(p.state.midiState, .learning)
        host.midiSource.send(.controlChange(channel: 0, controller: 21, value: 99))
        XCTAssertEqual(p.state.midiState, .assigned)
        XCTAssertEqual(p.value, 0, "the learning message does not move it")
        host.midiSource.send(.controlChange(channel: 0, controller: 21, value: 127))
        XCTAssertEqual(p.value, 10)
        host.midiSource.send(.controlChange(channel: 0, controller: 22, value: 0))
        XCTAssertEqual(p.value, 10)
        XCTAssertEqual(seen.values, [0, 10])
        withExtendedLifetime(token) {}
    }

    func testResetGlidesUnderTheClock() throws {
        let host = Host()
        let p = LiveParameter(state: try state(value: 2), environment: host)
        p.setManualValue(10)
        host.step(1)    // let the smoothing settle first
        XCTAssertEqual(host.clockSource.active, 0)
        p.reset()
        XCTAssertEqual(host.clockSource.active, 1)
        host.step(0.15)
        XCTAssertEqual(p.value, 6, accuracy: 1e-9)
        host.step(0.15)
        XCTAssertEqual(p.value, 2, accuracy: 1e-9)
        host.step(1)
        XCTAssertEqual(host.clockSource.active, 0)
    }

    func testTheEnvironmentIsHeldWeaklyAndCanBeReplaced() throws {
        var host: Host? = Host()
        weak var weakHost = host
        let p = LiveParameter(state: try state(), environment: host)
        host?.registry[p.id] = p      // a registry that holds the parameter must not keep the host alive via it
        host = nil
        XCTAssertNil(weakHost)
        XCTAssertNil(p.environment)
        p.setManualValue(3)
        XCTAssertEqual(p.value, 3, "still works with no host")

        let first = Host(), second = Host()
        let q = LiveParameter(state: try state(), environment: first)
        q.edit { $0.assign(try! LiveMIDIAddress(kind: .control, channel: 0, number: 1)) }
        XCTAssertEqual(first.midiSource.active, 1)
        q.attach(to: second)
        XCTAssertEqual(first.midiSource.active, 0); XCTAssertEqual(second.midiSource.active, 1)
    }

    func testLiveClockSkipsEachSubscribersFirstStepAndReportsTheTempo() {
        let queue = DispatchQueue(label: "LiveClockTests")
        let ticks = Recorder<LiveClockTick>()
        final class Reads: @unchecked Sendable { let lock = NSLock(); var t = 10.0
            func next() -> Double { lock.lock(); defer { lock.unlock() }; t += 0.25; return t } }
        let reads = Reads()
        let timer = XTimer(every: 0.005, queue: queue, now: { reads.next() })
        let clock = LiveClock(timer: timer, bpm: { 128 })
        let lock = NSLock()
        let token = clock.sink { tick in lock.lock(); ticks.values.append(tick); lock.unlock() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline { lock.lock(); let n = ticks.values.count; lock.unlock(); if n >= 3 { break }; Thread.sleep(forTimeInterval: 0.005) }
        token.cancel()
        lock.lock(); let seen = ticks.values; lock.unlock()
        XCTAssertGreaterThanOrEqual(seen.count, 3)
        XCTAssertEqual(seen[0], LiveClockTick(deltaTime: 0.25, bpm: 128), "the first firing only sets the starting time")
    }
}
