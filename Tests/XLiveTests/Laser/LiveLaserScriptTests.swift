import XCTest
import XLive
import XLaser

private final class RecordingScript: LaserScriptable {
    let descriptor = LaserDescriptor(name: "Test")
    var reads = 0
    var contexts: [LaserReadContext] = []
    var received: [[String: LaserInput]] = []
    var fails = false

    func read(context: LaserReadContext, inputs: [String: LaserInput], output: inout Laser3DBuffer) throws {
        reads += 1
        contexts.append(context)
        received.append(inputs)
        try output.beginShape(id: 1)
        try output.appendVertex(LaserVertex(x: Double(reads), y: 0))
        if fails { throw Failure.failed }
    }

    enum Failure: Error { case failed }
}

final class LiveLaserScriptTests: XCTestCase {
    func testKeepsScriptAndForwardsContextAndInputs() throws {
        let script = RecordingScript()
        let node = LiveLaserScript(script)
        let context = LaserReadContext(time: 2, sampleRate: 30000, frameLength: 250)
        var output = Laser3DBuffer()
        try node.read(context: context, inputs: ["speed": .float(2)], output: &output)
        try node.read(context: context, inputs: [:], output: &output)
        XCTAssertEqual(node.descriptor.name, "Test")
        XCTAssertEqual(script.reads, 2)
        XCTAssertEqual(script.contexts, [context, context])
        XCTAssertEqual(script.received.first?["speed"], .float(2))
    }

    func testClearsPartialOutputWhenScriptFails() throws {
        let script = RecordingScript()
        script.fails = true
        let node = LiveLaserScript(script)
        var output = Laser3DBuffer()
        XCTAssertThrowsError(try node.read(context: .init(time: 0, sampleRate: 30000, frameLength: 250), output: &output))
        XCTAssertEqual(output.vertexCount, 0)
    }
}
