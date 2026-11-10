import Foundation
@testable import XLive

struct TestShape {
    let id: LaserShapeID
    let vertices: [LaserVertex]
}

func testBuffer(_ shapes: [TestShape]) -> Laser3DBuffer {
    var buffer = Laser3DBuffer()
    for shape in shapes {
        try! buffer.beginShape(id: shape.id)
        for vertex in shape.vertices { try! buffer.appendVertex(vertex) }
    }
    return buffer
}

func FixedFrame(_ shapes: [TestShape]) -> LaserLive<Laser3DBuffer> {
    LaserLive(testBuffer(shapes))
}

extension LaserProjector {
    mutating func project(_ shapes: [TestShape]) -> [Laser2DShape] { project(testBuffer(shapes)) }
}
