import XCTest
import XMIDI

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
}
