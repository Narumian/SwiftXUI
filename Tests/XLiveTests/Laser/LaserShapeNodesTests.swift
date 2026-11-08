import XCTest
import XLive
import XUI

/// A square whose size follows a `LiveParameterLFOSimple`, to try the contract of `LaserGeometry`.
private struct TestSquare: LaserGeometry {
    var size = try! LiveParameterLFOSimple(value: 0.5, range: 0...1, lfo: try! LiveLFO(period: .seconds(4)))

    mutating func update(context: LiveUpdateContext) async { size.update(context: context) }

    func process(_: Void) -> LaserChunk<LaserVertex> {
        let s = size.value
        let corners: [LaserVertex] = [
            .init(x: -s, y: -s), .init(x: s, y: -s), .init(x: s, y: s), .init(x: -s, y: s), .init(x: -s, y: -s),
        ]
        return LaserChunk(elements: corners, shape: 1)
    }
}

/// Two copies of a frame with a blank vertex between them, each copy its own run.
private struct TestTwice: LaserEffect {
    mutating func update(context: LiveUpdateContext) async {}

    func process(_ frame: LaserChunk<LaserVertex>) -> LaserChunk<LaserVertex> {
        guard let first = frame.elements.first, let last = frame.elements.last else { return frame }
        var elements = frame.elements
        elements.append(last.blanked())
        elements.append(first.blanked())
        elements.append(contentsOf: frame.elements)
        let n = frame.count
        return LaserChunk(elements: elements, runs: [
            LaserRun(id: 1, range: 0..<n),
            LaserRun(id: 2, range: (n + 2)..<(2 * n + 2)),
        ])
    }
}

final class LaserShapeNodesTests: XCTestCase {
    func testProcessDoesNotChangeTheNodeAndTimeMovesOnlyInUpdate() async {
        var square = TestSquare()
        let before = square.process(())
        XCTAssertEqual(before.elements, square.process(()).elements)

        await square.update(context: LiveUpdateContext(deltaTime: 1))
        let after = square.process(())
        XCTAssertNotEqual(before.elements, after.elements)
        XCTAssertEqual(after.elements, square.process(()).elements)
    }

    func testNodesSurviveASaveAndReload() async throws {
        var square = TestSquare()
        await square.update(context: LiveUpdateContext(deltaTime: 1.3))
        let restored = try JSONDecoder().decode(TestSquare.self, from: JSONEncoder().encode(square))
        XCTAssertEqual(restored.process(()).elements, square.process(()).elements)

        // Through the protocol, as a host that holds `any LaserEffect` would.
        let effect: any LaserEffect = TestTwice()
        XCTAssertNoThrow(try JSONEncoder().encode(effect))
    }

    func testGeometryReturnsOneWholeShape() {
        let frame = TestSquare().process(())
        XCTAssertEqual(frame.runs, [LaserRun(id: 1, range: 0..<frame.count)])
    }

    func testEffectCutsItsOwnRunsAndPadsNothing() {
        let frame = TestSquare().process(())
        let out = TestTwice().process(frame)
        XCTAssertEqual(out.count, frame.count * 2 + 2)
        XCTAssertEqual(out.runs.map(\.id), [1, 2])
        // The gap between the copies is blank and belongs to no run.
        XCTAssertTrue(out.elements[frame.count].isBlanked)
        XCTAssertTrue(out.elements[frame.count + 1].isBlanked)
        XCTAssertEqual(out.runs[0].range.upperBound + 2, out.runs[1].range.lowerBound)
        XCTAssertEqual(out.runs[1].range.upperBound, out.count)
    }

    func testEffectedFramesGetPaddedPerRunByDwellBlank() {
        var pad = LaserDwellBlank(dwell: 2, blank: 2)
        let out = pad.process(TestTwice().process(TestSquare().process(())))
        // Each of the two runs gains 2 blank + 2 dwell in front and 2 dwell + 1 blank behind.
        XCTAssertEqual(out.runs.count, 2)
        XCTAssertGreaterThan(out.count, 2 * 5 + 2)
    }
}
