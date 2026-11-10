import XCTest
import XLive
import XUI

/// A square whose size follows a `LiveParameterLFOSimple`, to try the contract of `LaserGeometry`.
private struct TestSquare: LaserGeometry {
    var size = try! LiveParameterLFOSimple(value: 0.5, range: 0...1, lfo: try! LiveLFO(period: .seconds(4)))

    mutating func update(context: LiveUpdateContext) async { size.update(context: context) }

    func process(_: Void) -> Laser3DBuffer {
        let s = size.value
        let corners: [LaserVertex] = [
            .init(x: -s, y: -s), .init(x: s, y: -s), .init(x: s, y: s), .init(x: -s, y: s), .init(x: -s, y: -s),
        ]
        return testBuffer([TestShape(id: 1, vertices: corners)])
    }
}

/// Two copies of a frame, each its own shape. Nothing is put between them.
private struct TestTwice: LaserEffect {
    mutating func update(context: LiveUpdateContext) async {}

    func process(_ frame: Laser3DBuffer) -> Laser3DBuffer {
        var output = frame
        try! output.append(contentsOf: frame.mapShapeIDs { LaserShapeID($0.rawValue + 1000) })
        return output
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
        XCTAssertEqual(frame.shapes.map(\.id), [1])
        XCTAssertEqual(frame.shapes[0].count, 5)
    }

    func testEffectMakesCopiesAsShapesOfTheirOwnAndPadsNothing() {
        let frame = TestSquare().process(())
        let out = TestTwice().process(frame)
        XCTAssertEqual(out.shapes.map(\.id), [1, 1001])
        XCTAssertEqual(out.shapes.map(\.count), [5, 5])
    }

    func testEffectedFramesGetPaddedPerShapeByDwellBlank() {
        var pad = LaserDwellBlank(dwell: 2, blank: 2)
        let frame = TestTwice().process(TestSquare().process(()))
        let points = frame.shapes.map { shape in
            Laser2DShape(id: shape.id, points: (Int(shape.start)..<(Int(shape.start) + Int(shape.count))).map {
                let vertex = frame.vertex(at: $0)
                return try! LaserPoint(xy: SIMD2(Float(vertex.position.x), Float(vertex.position.y)), rgb: SIMD3(repeating: 1))
            })
        }
        let out = pad.process(points)
        // Each of the two shapes gains 2 blank + 2 dwell in front and 2 dwell + 1 blank behind.
        XCTAssertEqual(out.map(\.id), [1, 1001])
        XCTAssertEqual(out.map { $0.points.count }, [5 + 4 + 3, 5 + 4 + 3])
    }
}
