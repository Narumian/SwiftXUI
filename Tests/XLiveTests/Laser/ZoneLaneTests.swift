import Foundation
import XCTest
@testable import XLive

/// A ramp whose point `i` carries `i` in its x, in frames of every length, so a test can read where in the zone a
/// device is by the point it plays.
private struct Ramp: AsyncSequence, Sendable {
    typealias Element = [LaserPoint]
    static let total = 2_400_000
    let lengths = [7, 1000, 313, 4000, 50, 2, 1500, 999]
    struct Iterator: AsyncIteratorProtocol {
        let lengths: [Int]
        var index = 0, frame = 0
        mutating func next() async -> [LaserPoint]? {
            let length = lengths[frame % lengths.count]
            frame += 1
            let points = (index..<(index + length)).map {
                try! LaserPoint(xy: SIMD2(Float($0) / Float(Ramp.total) * 2 - 1, 0), rgb: SIMD3(1, 1, 1), mode: .normal)
            }
            index += length
            return points
        }
    }
    func makeAsyncIterator() -> Iterator { Iterator(lengths: lengths) }
}

private func zoneIndex(of point: LaserPoint) -> Double { Double((point.xy.x + 1) / 2) * Double(Ramp.total) }

/// A device that plays what it was given at its own clock and holds a queue, like a credit-paced laser.
private final class SimDevice {
    let rate: Double, skew: Double, queueTarget: Int
    let lane: ZoneLane
    var queue: [LaserPoint] = []
    var owed = 0.0
    var played = 0
    var lastPlayed: LaserPoint?
    var lastIndex = 0.0
    var reversals = 0
    var starvedPlays = 0
    var stalledUntil = 0.0

    init(zone: ZoneProducer, rate: UInt32, skewPPM: Double, queueSeconds: Double = 0.2, now: Double, settings: ZoneLaneSettings = ZoneLaneSettings()) {
        self.rate = Double(rate); skew = skewPPM / 1_000_000; queueTarget = Int(Double(rate) * queueSeconds)
        lane = ZoneLane(ring: zone.ring, zoneRate: zone.rate, outputRate: rate, epoch: zone.epoch, now: now, settings: settings)
    }

    /// The first fill, before the device plays anything.
    func prime(now: Double) { while queue.count < queueTarget { queue.append(contentsOf: lane.makeBlock(count: 140, now: now, queued: queue.count)) } }

    /// Plays for `dt` seconds, then, if the link is up, tops the queue up the way credit-paced writes do.
    func step(dt: Double, now: Double) {
        owed += rate * (1 + skew) * dt
        let due = Int(owed); owed -= Double(due)
        let taken = min(due, queue.count)
        starvedPlays += due - taken
        for point in queue.prefix(taken) {
            let index = zoneIndex(of: point)
            if index + 1 < lastIndex, !point.isBlanked { reversals += 1 }
            lastIndex = max(lastIndex, index)
            lastPlayed = point
        }
        queue.removeFirst(taken); played += taken
        guard now >= stalledUntil else { return }
        while queue.count < queueTarget {
            queue.append(contentsOf: lane.makeBlock(count: 140, now: now, queued: queue.count))
        }
    }

    /// Where in the zone the device is playing, in zone points.
    var playingIndex: Double { lastPlayed.map(zoneIndex(of:)) ?? 0 }
}

final class ZoneLaneTests: XCTestCase {
    private func run(seconds: Double, devices: (ZoneProducer, Double) -> [SimDevice],
                     between: (Double, [SimDevice]) -> Void = { _, _ in }) async -> (ZoneProducer, [SimDevice], Double) {
        let clock = ManualZoneClock(start: 100)
        let producer = ZoneProducer(source: Ramp(), rate: 50_000, clock: clock, horizon: 0.25)
        await producer.produce(upTo: clock.now + producer.horizon)
        let sims = devices(producer, clock.now)
        for device in sims { device.prime(now: clock.now) }
        let dt = 0.0005
        var t = 0.0
        while t < seconds {
            t += dt
            clock.advance(to: 100 + t)
            await producer.produce(upTo: clock.now + producer.horizon)
            between(t, sims)
            for device in sims { device.step(dt: dt, now: clock.now) }
        }
        return (producer, sims, t)
    }

    func testDevicesOfDifferentRatesAndClocksAllFollowTheOneZoneWithoutJumping() async {
        let (producer, sims, t) = await run(seconds: 8) { producer, now in
            [SimDevice(zone: producer, rate: 30_000, skewPPM: 0, now: now),
             SimDevice(zone: producer, rate: 20_000, skewPPM: 0, now: now),
             SimDevice(zone: producer, rate: 30_000, skewPPM: 100, now: now),     // +0.01%
             SimDevice(zone: producer, rate: 30_000, skewPPM: -300, now: now)]
        }
        let wanted = t * Double(producer.rate)
        for (n, device) in sims.enumerated() {
            let queuedZone = Double(device.queue.count) * device.lane.nominalStep
            // What it plays now is what the zone was a queue ago: the playing position is the read position less the queue.
            let error = (device.playingIndex - (wanted - 0)) / Double(producer.rate)
            XCTAssertLessThan(abs(error), 0.020, "device \(n) plays within 20 ms of the zone's time (\(error * 1000) ms; queued \(queuedZone))")
            XCTAssertEqual(device.lane.jumps, 0, "device \(n)")
            XCTAssertEqual(device.lane.skippedSamples, 0, "device \(n)")
            XCTAssertEqual(device.lane.underrunSamples, 0, "device \(n)")
            XCTAssertEqual(device.reversals, 0, "device \(n) never plays backwards")
            XCTAssertEqual(device.starvedPlays, 0, "device \(n) never ran dry")
            XCTAssertLessThan(abs(device.lane.errorSeconds), 0.003, "device \(n) error \(device.lane.errorSeconds * 1000) ms")
        }
        // The fast and the slow clocks are held to the same zone time by the trim, within its limit.
        XCTAssertGreaterThan(sims[3].lane.trim, 0, "the slow device is stepped faster through the zone")
        XCTAssertLessThan(sims[2].lane.trim, 0, "the fast device is stepped slower")
        XCTAssertLessThan(abs(sims[2].lane.trim), 0.005)
    }

    func testADeviceWhoseClockIsOffByAPercentIsLearnedAndHeldInStepWithoutJumping() async {
        // The real cube's clock was found to be about 0.6% off. A proportional trim alone would settle `skew * 2 s` away
        // (12 ms) or give up at its limit; the integral part takes the error to zero.
        let (producer, sims, t) = await run(seconds: 40) { producer, now in
            [SimDevice(zone: producer, rate: 30_000, skewPPM: -6000, now: now),
             SimDevice(zone: producer, rate: 30_000, skewPPM: 9000, now: now),
             SimDevice(zone: producer, rate: 20_000, skewPPM: -6000, now: now)]
        }
        let wanted = t * Double(producer.rate)
        for (n, device) in sims.enumerated() {
            XCTAssertEqual(device.lane.jumps, 0, "device \(n)")
            XCTAssertLessThan(abs(device.lane.errorSeconds), 0.003, "device \(n) error \(device.lane.errorSeconds * 1000) ms")
            XCTAssertLessThan(abs(device.playingIndex - wanted) / Double(producer.rate), 0.03, "device \(n)")
            XCTAssertEqual(device.starvedPlays, 0, "device \(n)")
        }
        XCTAssertEqual(sims[0].lane.trim, 0.006, accuracy: 0.002, "the slow device is stepped 0.6% faster")
        XCTAssertEqual(sims[1].lane.trim, -0.009, accuracy: 0.002)
    }

    func testALongStallDoesNotWindUpTheLearnedClockErrorSoTheDeviceSettlesAfterOneJump() async {
        let (_, sims, _) = await run(seconds: 40, devices: { producer, now in
            [SimDevice(zone: producer, rate: 30_000, skewPPM: -6000, now: now)]
        }, between: { t, sims in
            if abs(t - 12) < 0.0003 { sims[0].stalledUntil = 100 + 12.9 }
        })
        XCTAssertEqual(sims[0].lane.jumps, 1, "one jump for the one stall, none after")
        XCTAssertLessThan(abs(sims[0].lane.errorSeconds), 0.004, "settled again, \(sims[0].lane.errorSeconds * 1000) ms")
        XCTAssertEqual(sims[0].lane.trim, 0.006, accuracy: 0.002, "it still knows the clock is slow")
    }

    func testALinkStallShorterThanTheQueueIsAbsorbedWithoutJumpingOrTouchingTheOtherDevice() async {
        let (_, sims, _) = await run(seconds: 6, devices: { producer, now in
            [SimDevice(zone: producer, rate: 30_000, skewPPM: 0, now: now),
             SimDevice(zone: producer, rate: 20_000, skewPPM: 0, now: now)]
        }, between: { t, sims in
            if abs(t - 3) < 0.0003 { sims[1].stalledUntil = 100 + 3.09 }   // ~90 ms, the Wi-Fi stall
        })
        XCTAssertEqual(sims[1].lane.jumps, 0, "the queue held more than the stall")
        XCTAssertEqual(sims[1].starvedPlays, 0)
        XCTAssertLessThan(abs(sims[1].lane.errorSeconds), 0.01)
        XCTAssertEqual(sims[0].lane.jumps, 0); XCTAssertEqual(sims[0].lane.skippedSamples, 0)
    }

    func testALongStallJumpsOnlyThatDeviceAndCountsIt() async {
        let (producer, sims, t) = await run(seconds: 8, devices: { producer, now in
            [SimDevice(zone: producer, rate: 30_000, skewPPM: 0, now: now),
             SimDevice(zone: producer, rate: 20_000, skewPPM: 0, now: now)]
        }, between: { t, sims in
            if abs(t - 3) < 0.0003 { sims[1].stalledUntil = 100 + 3.8 }   // far longer than its queue
        })
        XCTAssertEqual(sims[1].lane.jumps, 1)
        XCTAssertGreaterThan(sims[1].lane.skippedSamples + sims[1].lane.jumpedSamples, 0)
        XCTAssertGreaterThan(sims[1].starvedPlays, 0, "the device itself ran dry while stalled")
        XCTAssertEqual(sims[0].lane.jumps, 0); XCTAssertEqual(sims[0].lane.skippedSamples, 0)
        // After the jump it is back in step with the zone.
        let wanted = t * Double(producer.rate)
        XCTAssertLessThan(abs(sims[1].playingIndex - wanted) / Double(producer.rate), 0.02)
        XCTAssertEqual(sims[1].reversals, 0)
    }

    func testAJumpLandsOnTheStartOfAFrame() async {
        let clock = ManualZoneClock(start: 0)
        let producer = ZoneProducer(source: Ramp(), rate: 50_000, clock: clock, horizon: 0.25)
        await producer.produce(upTo: 0.25)
        // A lane that starts far behind where it should be (the clock is a second ahead of the ring's data)
        let lane = ZoneLane(ring: producer.ring, zoneRate: 50_000, outputRate: 50_000, epoch: 0, now: 0)
        _ = lane.makeBlock(count: 100, now: 0)
        clock.advance(to: 0.25)
        await producer.produce(upTo: 0.5)
        let block = lane.makeBlock(count: 10, now: 0.4, queued: 0)   // 0.4 s: the lane is 0.3 s behind
        XCTAssertEqual(lane.jumps, 1)
        let first = zoneIndex(of: block[0])
        let desired = 0.4 * 50_000
        XCTAssertGreaterThanOrEqual(first, desired - 1)
        XCTAssertLessThanOrEqual(first - desired, 0.03 * 50_000 + 1, "no further ahead than half the jump threshold")
    }

    func testAnEmptyZonePlaysDarkAndCountsItWithoutStopping() {
        let ring = ZoneRing(capacity: 1000)
        let lane = ZoneLane(ring: ring, zoneRate: 30_000, outputRate: 30_000, epoch: 0, now: 0)
        let block = lane.makeBlock(count: 50, now: 0)
        XCTAssertEqual(block.count, 50)
        XCTAssertTrue(block.allSatisfy { $0.isBlanked })
        XCTAssertEqual(lane.underrunSamples, 50)
        ring.write((0..<100).map { _ in try! LaserPoint(xy: SIMD2(0.5, 0), rgb: SIMD3(1, 1, 1), mode: .normal) })
        XCTAssertTrue(lane.makeBlock(count: 20, now: 0.001).allSatisfy { !$0.isBlanked }, "it plays again as soon as there is something")
    }

    func testTheProducerKeepsTheCursorAtNowPlusHorizonWhateverTheFrameLength() async {
        let clock = ManualZoneClock(start: 10)
        let producer = ZoneProducer(source: Ramp(), rate: 50_000, clock: clock, horizon: 0.25)
        for step in 1...200 {
            clock.advance(to: 10 + Double(step) * 0.01)
            await producer.produce(upTo: clock.now + 0.25)
            let target = Int((clock.now + 0.25 - 10) * 50_000)
            let written = producer.ring.writtenCount
            XCTAssertGreaterThanOrEqual(written, target)
            XCTAssertLessThan(written - target, 4000, "ahead by at most one frame")
        }
    }
}
