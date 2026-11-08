import XCTest
import XLive

final class LiveSignalsTests: XCTestCase {
    func testAudioBandsReadAndClamp() {
        let levels = LiveAudioLevels(peak: 0.9, low: 0.1, mid: 2, high: .nan)
        XCTAssertEqual(LiveAudioBand.peak.level(in: levels), 0.9)
        XCTAssertEqual(LiveAudioBand.low.level(in: levels), 0.1)
        XCTAssertEqual(LiveAudioBand.mid.level(in: levels), 1)
        XCTAssertEqual(LiveAudioBand.high.level(in: levels), 0)
    }

    func testMotionAxesMapToUnitRange() {
        let sample = LiveMotionSample(acceleration: .init(x: 1, y: -1, z: 0), gravity: .init(x: 0, y: 0.5, z: -3),
                                      roll: .pi / 2, pitch: -.pi, yaw: 0)
        XCTAssertEqual(LiveMotionAxis.accelX.normalized(from: sample), 1)
        XCTAssertEqual(LiveMotionAxis.accelY.normalized(from: sample), 0)
        XCTAssertEqual(LiveMotionAxis.accelZ.normalized(from: sample), 0.5)
        XCTAssertEqual(LiveMotionAxis.gravityY.normalized(from: sample), 0.75)
        XCTAssertEqual(LiveMotionAxis.gravityZ.normalized(from: sample), 0, "clamped")
        XCTAssertEqual(LiveMotionAxis.roll.normalized(from: sample), 0.75, accuracy: 1e-12)
        XCTAssertEqual(LiveMotionAxis.pitch.normalized(from: sample), 0, accuracy: 1e-12)
        XCTAssertEqual(LiveMotionAxis.yaw.normalized(from: sample), 0.5)
        XCTAssertEqual(LiveMotionAxis.accelYAbs.normalized(from: sample), 1)
        XCTAssertEqual(LiveMotionAxis.gravityZAbs.normalized(from: sample), 1, "clamped")
        for axis in LiveMotionAxis.allCases {
            XCTAssertTrue((0...1).contains(axis.normalized(from: LiveMotionSample(roll: .nan, pitch: .infinity))))
        }
    }

    func testSourceDescriptorsRoundTripAndCenters() throws {
        let sources: [LiveSourceDescriptor] = [
            .audio(.low), .motion(.pitch), .midiControl(channel: 0, controller: 74),
            .midiNote(channel: 9, note: 36), .gamepad(id: "pad-1"), .parameter(LiveObjectID(rawValue: "pace")),
        ]
        let data = try JSONEncoder().encode(sources)
        XCTAssertEqual(try JSONDecoder().decode([LiveSourceDescriptor].self, from: data), sources)
        XCTAssertEqual(LiveSourceDescriptor.audio(.peak).amountCenter, 0)
        XCTAssertEqual(LiveSourceDescriptor.motion(.roll).amountCenter, 0.5)
        XCTAssertEqual(Set(sources).count, sources.count)
    }
}
