import XCTest
import XCombine
import XLive

final class MIDIInputTests: XCTestCase {
    func testRunningStatusSplitMessagesAndRealtime() {
        var parser = MIDI1InputParser()
        XCTAssertEqual(parser.receive([0x92, 60]), [])
        XCTAssertEqual(parser.receive([0xF8, 100, 61, 0]), [.noteOn(channel: 2, note: 60, velocity: 100), .noteOff(channel: 2, note: 61, velocity: 0)])
        XCTAssertEqual(parser.receive([0xB3, 7, 127, 8, 42]), [.controlChange(channel: 3, controller: 7, value: 127), .controlChange(channel: 3, controller: 8, value: 42)])
    }
    func testSystemAndOtherChannelMessagesDoNotProduceNotes() {
        var parser = MIDI1InputParser()
        XCTAssertEqual(parser.receive([0x90, 1, 2, 0xF0, 0x01, 0x02, 0xF7, 0x03, 0x04, 0xC0, 10, 11, 0x80, 1, 9]), [.noteOn(channel: 0, note: 1, velocity: 2), .noteOff(channel: 0, note: 1, velocity: 9)])
    }

    /// A backend queues on its own thread; the owner drains, and every subscriber sees every event.
    func testConnectionEventsReachEverySubscriberAfterDrain() {
        final class FakeConnection: MIDIInputConnection, @unchecked Sendable {
            let events = XInbox<MIDIInputEvent>(overflow: .dropOldest(capacity: 8))
            func disconnect() {}
        }
        let connection = FakeConnection()
        var notes: [UInt8] = []
        var controllers: [UInt8] = []
        let onNotes = connection.events.compactMap { event -> UInt8? in
            if case .noteOn(_, let note, _) = event.message { return note } else { return nil }
        }.sink { notes.append($0) }
        let onControllers = connection.events.compactMap { event -> UInt8? in
            if case .controlChange(_, let controller, _) = event.message { return controller } else { return nil }
        }.sink { controllers.append($0) }
        let producer = Thread {
            connection.events.send(.init(sourceID: "a", message: .noteOn(channel: 0, note: 60, velocity: 100), timestamp: 1))
            connection.events.send(.init(sourceID: "a", message: .controlChange(channel: 0, controller: 7, value: 9), timestamp: 2))
        }
        producer.start()
        while connection.events.pendingCount < 2 { Thread.sleep(forTimeInterval: 0.001) }
        connection.events.drain()
        XCTAssertEqual(notes, [60])
        XCTAssertEqual(controllers, [7])
        withExtendedLifetime((onNotes, onControllers)) {}
    }
}
