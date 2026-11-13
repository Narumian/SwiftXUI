import Foundation
import XCTest
@testable import XLive

/// The ring promises that a reader never holds back the writer or another reader, whatever its pace, and that a reader
/// the ring has turned past is told what it lost. Time is a clock the test moves by hand.
/// A point that carries its own number (14 bits, exact in a Float), so a reader can check what it was given.
private func point(_ index: Int) -> LaserPoint {
    try! LaserPoint(xy: SIMD2(Float(index & 0x3fff) / 8192 - 1, 0), rgb: .zero, mode: .normal)
}
private func number(_ point: LaserPoint) -> Int { Int(((point.xy.x + 1) * 8192).rounded()) }
private func points(_ range: Range<Int>) -> [LaserPoint] { range.map(point) }
/// True when `read` is the points numbered `start...`, in order.
private func continues(_ read: [LaserPoint], from start: Int) -> Bool {
    read.enumerated().allSatisfy { number($1) == (start + $0) & 0x3fff }
}

final class ZoneRingTests: XCTestCase {
    func testAReaderReadsWhatWasWrittenInOrderAndAReadPastTheEndIsShortAndCounted() {
        let ring = ZoneRing(capacity: 64)
        let reader = ring.makeReader()
        ring.write(points(0..<10))
        let first = reader.read(4), rest = reader.read(10)
        XCTAssertTrue(continues(first, from: 0)); XCTAssertEqual(first.count, 4)
        XCTAssertTrue(continues(rest, from: 4)); XCTAssertEqual(rest.count, 6)
        XCTAssertEqual(reader.starvedSamples, 4)
        XCTAssertEqual(reader.lostSamples, 0); XCTAssertEqual(reader.position, 10); XCTAssertEqual(reader.lag, 0)
    }

    func testAReaderStartsWhereItWasMadeNotAtTheBeginning() {
        let ring = ZoneRing(capacity: 64)
        ring.write(points(0..<20))
        XCTAssertEqual(ring.makeReader().position, 20)
        XCTAssertEqual(ring.makeReader(lag: 5).position, 15)
        XCTAssertEqual(ring.makeReader(lag: 1000).position, 0, "no further back than what is held")
        ring.write(points(20..<100))
        XCTAssertEqual(ring.makeReader(lag: 1000).position, 100 - 64)
    }

    func testTheWriterNeverWaitsAndAReaderTheRingTurnedPastIsMovedToTheOldestAndToldWhatItLost() {
        let ring = ZoneRing(capacity: 8)
        let reader = ring.makeReader()
        ring.write(points(0..<13))   // five more than the ring holds
        let read = reader.read(100)
        XCTAssertEqual(read.count, 8)
        XCTAssertTrue(continues(read, from: 5))
        XCTAssertEqual(reader.lostSamples, 5)
        XCTAssertEqual(ring.oldestIndex, 5); XCTAssertEqual(ring.writtenCount, 13)
    }

    func testAWriteLargerThanTheRingKeepsItsLastPoints() {
        let ring = ZoneRing(capacity: 8)
        let reader = ring.makeReader()
        ring.write(points(0..<30))
        XCTAssertTrue(continues(reader.read(8), from: 22))
        XCTAssertEqual(reader.lostSamples, 22)
    }

    func testAStoppedReaderDoesNotHoldBackTheWriterOrAnotherReader() {
        let ring = ZoneRing(capacity: 512)
        let steady = ring.makeReader(), stopped = ring.makeReader()
        var next = 0, seen = 0
        var ok = true
        // 2000 ticks of 1 ms; the zone makes 50 points a tick. `steady` reads each tick, `stopped` never does.
        for _ in 0..<2000 {
            ring.write(points(next..<(next + 50)))
            next += 50
            let read = steady.read(50)
            ok = ok && continues(read, from: seen) && read.count == 50
            seen += read.count
        }
        XCTAssertTrue(ok); XCTAssertEqual(steady.lostSamples, 0); XCTAssertEqual(steady.starvedSamples, 0)
        XCTAssertEqual(ring.writtenCount, 100_000)
        // It comes back after a long time: it is moved to the oldest point, and what it missed is counted.
        let late = stopped.read(512)
        XCTAssertEqual(stopped.lostSamples, 100_000 - 512)
        XCTAssertTrue(continues(late, from: 100_000 - 512))
    }

    func testReadersAtDifferentPacesEachSeeTheWholeStreamWhileTheyKeepUp() {
        // The zone makes frames of every length; two outputs read at their own pace (bursty, and in uneven steps).
        let ring = ZoneRing(capacity: 16384)
        let bursty = ring.makeReader(), stepped = ring.makeReader()
        let frames = [7, 1000, 313, 4000, 50, 2, 1500, 999]
        var written = 0, burstySeen = 0, steppedSeen = 0
        var ok = true
        for tick in 0..<4000 {
            // 50 points per tick in the long run, in frames of any length: a frame is written when the clock reaches it.
            while written < (tick + 1) * 50 {
                let length = frames[(written / 13) % frames.count]
                ring.write(points(written..<(written + length)), startsFrame: true)
                written += length
            }
            if tick % 10 == 9 {   // bursty reads what has accumulated every 10 ticks
                let read = bursty.read(bursty.lag)
                ok = ok && continues(read, from: burstySeen); burstySeen += read.count
            }
            let read = stepped.read(min(stepped.lag, 50 + 7 * (tick % 3)))
            ok = ok && continues(read, from: steppedSeen); steppedSeen += read.count
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(bursty.lostSamples, 0)
        XCTAssertEqual(bursty.position, burstySeen); XCTAssertEqual(stepped.position, steppedSeen)
        XCTAssertGreaterThan(burstySeen, 150_000)
    }

    func testAReaderThatSeeksToAFrameStartLandsOnAFrameAndCountsWhatItPassed() {
        let ring = ZoneRing(capacity: 100)
        let reader = ring.makeReader()
        ring.write(points(0..<30), startsFrame: true)
        ring.write(points(30..<50))
        ring.write(points(50..<90), startsFrame: true)
        XCTAssertEqual(reader.frameStart(atOrAfter: 0), 0)
        XCTAssertEqual(reader.frameStart(atOrAfter: 1), 50)
        XCTAssertNil(reader.frameStart(atOrAfter: 51))
        let landed = reader.seek(to: reader.frameStart(atOrAfter: 31)!)
        XCTAssertEqual(landed, 50)
        XCTAssertEqual(reader.skippedSamples, 50); XCTAssertEqual(reader.lostSamples, 0)
        XCTAssertTrue(continues(reader.read(40), from: 50))
    }

    func testFrameStartsThatTheRingTurnedPastAreForgotten() {
        let ring = ZoneRing(capacity: 100)
        let reader = ring.makeReader()
        for frame in 0..<10 { ring.write(points((frame * 30)..<(frame * 30 + 30)), startsFrame: true) }
        // 300 written; the ring holds 200...299, so the frames that begin at 210, 240, 270 remain.
        XCTAssertEqual(reader.frameStart(atOrAfter: 0), 210)
        XCTAssertEqual(reader.frameStart(atOrAfter: 211), 240)
        XCTAssertNil(reader.frameStart(atOrAfter: 271))
    }

    func testSeekIsKeptInsideWhatTheRingHolds() {
        let ring = ZoneRing(capacity: 10)
        let reader = ring.makeReader()
        ring.write(points(0..<25))
        XCTAssertEqual(reader.seek(to: 0), 15, "before the oldest point, to the oldest")
        XCTAssertEqual(reader.seek(to: 1000), 25, "beyond the writer, to the writer")
        XCTAssertEqual(reader.seek(to: 20), 20, "backwards is allowed and costs nothing")
        XCTAssertTrue(continues(reader.read(5), from: 20))
    }

    func testAWriterAndManyReadersOnOwnThreadsNeverBlockOrCorruptWhatIsRead() async {
        let ring = ZoneRing(capacity: 2048)
        let readers = (0..<4).map { _ in ring.makeReader() }
        let done = ManagedAtomicFlag()
        let writer = Task.detached {
            var written = 0
            while written < 300_000 {
                let length = 1 + (written * 7919) % 900
                ring.write((written..<(written + length)).map { point($0) })
                written += length
            }
            done.set()
        }
        var tasks: [Task<Bool, Never>] = []
        for (n, reader) in readers.enumerated() {
            tasks.append(Task.detached {
                var ok = true
                var expected: Int?
                while !done.isSet {
                    let before = reader.lostSamples
                    let read = reader.read(10 + n * 37)
                    // After a loss the reader is on the oldest point; from then on the points must follow one another.
                    if reader.lostSamples != before { expected = nil }
                    if let first = read.first {
                        if let expected { ok = ok && number(first) == expected & 0x3fff }
                        ok = ok && read.enumerated().allSatisfy { number($1) == (number(first) + $0) & 0x3fff }
                        expected = (expected ?? number(first)) + read.count
                    }
                    if n % 2 == 1 { try? await Task.sleep(nanoseconds: 50_000) }
                }
                return ok
            })
        }
        await writer.value
        for task in tasks { let result = await task.value; XCTAssertTrue(result) }
    }
}

private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
