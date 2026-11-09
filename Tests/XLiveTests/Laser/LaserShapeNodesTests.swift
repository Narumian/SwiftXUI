import XCTest
import XLive
import XUI

/// A square whose size follows a `LiveParameterLFOSimple`, to try the contract of `LaserGeometry`.
private struct TestSquare: LaserGeometry {
    var size = try! LiveParameterLFOSimple(value: 0.5, range: 0...1, lfo: try! LiveLFO(period: .seconds(4)))

    mutating func update(context: LiveUpdateContext) async { size.update(context: context) }

    func process(_: Void) -> [Laser3DShape] {
        let s = size.value
        let corners: [LaserVertex] = [
            .init(x: -s, y: -s), .init(x: s, y: -s), .init(x: s, y: s), .init(x: -s, y: s), .init(x: -s, y: -s),
        ]
        return [Laser3DShape(id: 1, vertices: corners)]
    }
}

/// Two copies of a frame, each its own shape. Nothing is put between them.
private struct TestTwice: LaserEffect {
    mutating func update(context: LiveUpdateContext) async {}

    func process(_ frame: [Laser3DShape]) -> [Laser3DShape] {
        frame + frame.map { Laser3DShape(id: LaserShapeID($0.id.rawValue + 1000), vertices: $0.vertices) }
    }
}

final class LaserShapeNodesTests: XCTestCase {
    func testProcessDoesNotChangeTheNodeAndTimeMovesOnlyInUpdate() async {
        var square = TestSquare()
        let before = square.process(())
        XCTAssertEqual(before, square.process(()))

        await square.update(context: LiveUpdateContext(deltaTime: 1))
        let after = square.process(())
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after, square.process(()))
    }

    func testNodesSurviveASaveAndReload() async throws {
        var square = TestSquare()
        await square.update(context: LiveUpdateContext(deltaTime: 1.3))
        let restored = try JSONDecoder().decode(TestSquare.self, from: JSONEncoder().encode(square))
        XCTAssertEqual(restored.process(()), square.process(()))

        // Through the protocol, as a host that holds `any LaserEffect` would.
        let effect: any LaserEffect = TestTwice()
        XCTAssertNoThrow(try JSONEncoder().encode(effect))
    }

    func testGeometryReturnsOneWholeShape() {
        let frame = TestSquare().process(())
        XCTAssertEqual(frame.map(\.id), [1])
        XCTAssertEqual(frame[0].vertices.count, 5)
    }

    func testEffectMakesCopiesAsShapesOfTheirOwnAndPadsNothing() {
        let frame = TestSquare().process(())
        let out = TestTwice().process(frame)
        XCTAssertEqual(out.map(\.id), [1, 1001])
        XCTAssertEqual(out.map { $0.vertices.count }, [5, 5])
    }

    func testEffectedFramesGetPaddedPerShapeByDwellBlank() {
        var pad = LaserDwellBlank(dwell: 2, blank: 2)
        let frame = TestTwice().process(TestSquare().process(()))
        let points = frame.map { shape in
            Laser2DShape(id: shape.id, points: shape.vertices.map { try! LaserPoint(xy: SIMD2(Float($0.position.x), Float($0.position.y)), rgb: SIMD3(repeating: 1)) })
        }
        let out = pad.process(points)
        // Each of the two shapes gains 2 blank + 2 dwell in front and 2 dwell + 1 blank behind.
        XCTAssertEqual(out.map(\.id), [1, 1001])
        XCTAssertEqual(out.map { $0.points.count }, [5 + 4 + 3, 5 + 4 + 3])
    }
}
