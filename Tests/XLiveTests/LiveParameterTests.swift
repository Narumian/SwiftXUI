import XCTest
import XLive
import XUI

private final class ParameterBox: @unchecked Sendable {
    var value: LiveParameter
    init(_ value: LiveParameter) { self.value = value }
}
private final class TestCanvas: XCanvas {
    func fillRect(_ rect: Rect, color: XColorValue) {}
    func drawText(_ string: String, in rect: Rect, fontSize: Double, font: TextFont, color: XColorValue, alignment: HorizontalAlignment, outline: TextOutline?) {}
}

final class LiveParameterTests: XCTestCase {
    func testBeatSyncLatchAndSmoothReturn() throws {
        var parameter = try LiveParameter(value: 0.5, lfo: LiveLFO(period: .beats(4)), returnDuration: 1)
        func context(_ dt: Double, _ beat: Double) -> LiveUpdateContext { .init(deltaTime: dt, tempo: .init(bpm: 120, beatPosition: beat)) }
        parameter.update(context: context(0, 1))
        XCTAssertEqual(parameter.value, 1, accuracy: 1e-10)
        parameter.setManualValue(0.2)
        parameter.update(context: context(0.5, 2))
        XCTAssertEqual(parameter.value, 0.2, accuracy: 1e-10)
        parameter.releaseManualControl()
        parameter.update(context: context(0.5, 2))
        XCTAssertEqual(parameter.mode, .returning)
        XCTAssertEqual(parameter.value, 0.35, accuracy: 1e-10)
        parameter.update(context: context(0.5, 3))
        XCTAssertEqual(parameter.mode, .automatic)
        XCTAssertEqual(parameter.value, 0, accuracy: 1e-10)
    }
    func testMissingTempoHoldsAndDragInterruptsReturn() throws {
        var parameter = try LiveParameter(value: 0.5, lfo: LiveLFO(period: .beats(4)))
        parameter.setManualValue(0.8)
        parameter.releaseManualControl()
        parameter.update(context: .init(deltaTime: 1))
        XCTAssertEqual(parameter.value, 0.8)
        XCTAssertEqual(parameter.mode, .returning)
        parameter.setManualValue(0.4)
        XCTAssertEqual(parameter.mode, .manual)
        XCTAssertEqual(parameter.value, 0.4)
    }
    @XUIActor
    func testDragAndKnobTap() async throws {
        let box = ParameterBox(try LiveParameter(value: 0.5, lfo: LiveLFO(period: .beats(4))))
        let binding = Binding<LiveParameter>(get: { box.value }, set: { box.value = $0 })
        let slider = LiveSlider(parameter: binding).frame(width: 200, height: 40)
        let host = LayoutHost(canvas: Size(width: 200, height: 40))
        var render = await host.render(slider, into: TestCanvas())
        var runtime = GestureRuntime()
        _ = runtime.handle(.init(phase: .began, position: Point(x: 100, y: 20)), in: render)
        _ = runtime.handle(.init(phase: .moved, position: Point(x: 150, y: 20)), in: render)
        _ = runtime.handle(.init(phase: .ended, position: Point(x: 150, y: 20)), in: render)
        XCTAssertEqual(box.value.mode, .manual)
        XCTAssertEqual(box.value.normalizedValue, 138 / 176, accuracy: 0.001)
        render = await host.render(slider, into: TestCanvas())
        _ = runtime.handle(.init(phase: .began, position: Point(x: 150, y: 20)), in: render)
        _ = runtime.handle(.init(phase: .ended, position: Point(x: 150, y: 20)), in: render)
        XCTAssertEqual(box.value.mode, .returning)
    }
}
