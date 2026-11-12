import XCTest
@testable import XLive
import XUI

private final class Recorder: XCanvas {
    struct Stroke { let points: Int; let color: XColorValue; let lineWidth: Double }
    var fills: [XColorValue] = []
    var strokes: [Stroke] = []
    var ellipses = 0
    var texts: [String] = []
    func fillRect(_ rect: Rect, color: XColorValue) { fills.append(color) }
    func fillRoundedRect(_ rect: Rect, cornerRadius: Double, color: XColorValue) { fills.append(color) }
    func fillEllipse(in rect: Rect, color: XColorValue) { ellipses += 1 }
    func strokePath(_ path: Path, in rect: Rect, color: XColorValue, lineWidth: Double) {
        strokes.append(Stroke(points: path.elements.count, color: color, lineWidth: lineWidth))
    }
    func drawText(_ string: String, in rect: Rect, fontSize: Double, font: TextFont, color: XColorValue,
                  alignment: HorizontalAlignment, outline: TextOutline?) { texts.append(string) }
}

private final class Box: @unchecked Sendable { var count = 0 }
private let tint = XColorValue(0.25, 0.6, 1)

final class LiveFaderKnobTests: XCTestCase {
    private func address(_ n: UInt8) -> LiveMIDIAddress { try! LiveMIDIAddress(kind: .control, channel: 0, number: n) }

    private func make(host: LiveParameterHost = LiveParameterHost()) throws -> (LiveParameterHost, LiveFaderBank, LiveParameter) {
        let p = host.add(try LiveParameterState(label: "Gain", value: 0.5))
        let bank = LiveFaderBank(count: 3, environment: host)
        bank.assign(address(1), to: 0)
        bank.setTargets([p, nil, nil])
        return (host, bank, p)
    }

    @XUIActor
    private func draw(_ bank: LiveFaderBank, onShow: (@Sendable () -> Void)? = nil) async -> (RenderResult, Recorder) {
        let canvas = Recorder()
        let view = LiveFaderKnob(bank: bank, slot: 0, tint: tint, onShowConfiguration: onShow)
        return (await LayoutHost(canvas: Size(width: 56, height: 90)).render(view, into: canvas), canvas)
    }

    // MARK: Geometry

    func testTheKnobSweepsTwoHundredSeventyDegreesFromTheLowerLeft() {
        XCTAssertEqual(LiveKnobGeometry.angle(0), 135)
        XCTAssertEqual(LiveKnobGeometry.angle(1), 405)
        XCTAssertEqual(LiveKnobGeometry.angle(7), 405, "clamped")
        XCTAssertEqual(LiveKnobGeometry.angle(.nan), 135)
        let g = LiveKnobGeometry(width: 56, height: 56)
        XCTAssertEqual(g.radius, 23)
        let top = g.point(0.5, radius: g.radius)
        XCTAssertEqual(top.x, 28, accuracy: 1e-9); XCTAssertEqual(top.y, 28 - 23, accuracy: 1e-9)
        let start = g.point(0, radius: g.radius, origin: Point(x: 10, y: 100))
        XCTAssertEqual(start.x, 10 + 28 - 23 * 0.5.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(start.y, 100 + 28 + 23 * 0.5.squareRoot(), accuracy: 1e-9, "lower left on a screen whose y points down")
    }

    func testAnArcRunsFromOneEndToTheOtherAlongTheRim() {
        let g = LiveKnobGeometry(width: 56, height: 56)
        let arc = g.arc(from: 0, to: 1, radius: g.radius)
        XCTAssertEqual(arc.first, g.point(0, radius: g.radius))
        XCTAssertEqual(arc.last, g.point(1, radius: g.radius))
        XCTAssertGreaterThan(arc.count, 20)
        XCTAssertEqual(g.arc(from: 0.3, to: 0.3, radius: g.radius).count, 2, "never empty")
        XCTAssertEqual(LiveKnobGeometry(width: .nan, height: -1).radius, 0)
    }

    func testDraggingUpTurnsTheKnobUpRelativeToWhereItWasGrabbed() {
        XCTAssertEqual(LiveKnobGeometry.draggedNormal(start: 0.5, translationY: -75)!, 1, accuracy: 1e-9)
        XCTAssertEqual(LiveKnobGeometry.draggedNormal(start: 0.5, translationY: 15)!, 0.4, accuracy: 1e-9)
        XCTAssertNil(LiveKnobGeometry.draggedNormal(start: .nan, translationY: 1))
    }

    // MARK: Drawing

    @XUIActor
    func testItShowsTheTargetsNameValueAndArc() async throws {
        let (_, bank, p) = try make()
        let (render, canvas) = await draw(bank)
        XCTAssertEqual(canvas.texts, ["Gain", "0.500"], "the value is cut to five characters")
        XCTAssertEqual(canvas.strokes.count, 3, "rim, value arc, pointer — and no waiting mark")
        XCTAssertEqual(canvas.strokes[1].color.opacity, 1)
        XCTAssertNotNil(render.dragGestures.first)
        p.setManualValue(0)
        let (_, empty) = await draw(bank)
        XCTAssertEqual(empty.strokes.count, 2, "a value at the very start has no arc")
    }

    @XUIActor
    func testASlotWithoutATargetIsEmptyAndCannotBeTurned() async throws {
        let (_, bank, _) = try make()
        bank.setTargets([nil, nil, nil])
        let (render, canvas) = await draw(bank)
        XCTAssertEqual(canvas.texts, ["empty"], "no value line")
        XCTAssertTrue(render.dragGestures.isEmpty)
        XCTAssertEqual(canvas.strokes.count, 1, "the rim only")
    }

    @XUIActor
    func testAnAutomatedTargetDimsTheKnobAndTakesNoDrag() async throws {
        let (_, bank, p) = try make()
        p.edit { $0.setSource(.lfo); $0.setAutomation(on: true) }
        let (render, canvas) = await draw(bank)
        XCTAssertTrue(render.dragGestures.isEmpty)
        XCTAssertEqual(canvas.strokes[1].color.opacity, 0.4, accuracy: 1e-9)
    }

    @XUIActor
    func testAWaitingControllerIsMarkedOutsideTheRim() async throws {
        let (host, bank, _) = try make()
        host.send(.controlChange(channel: 0, controller: 1, value: 0))
        XCTAssertTrue(bank.isWaiting(0))
        let (_, waiting) = await draw(bank)
        XCTAssertEqual(waiting.strokes.count, 4)
        XCTAssertEqual(waiting.strokes.last?.color, tint.opacity(0.9))
        host.send(.controlChange(channel: 0, controller: 1, value: 64))
        let (_, held) = await draw(bank)
        XCTAssertEqual(held.strokes.count, 3)
    }

    @XUIActor
    func testLabelColourShowsTheSlotsMIDIState() async throws {
        let (_, bank, _) = try make()
        var (_, canvas) = await draw(bank)
        XCTAssertEqual(canvas.fills.last(where: { $0 != .clear }), tint.opacity(0.5))
        bank.unassign(0)
        (_, canvas) = await draw(bank)
        XCTAssertEqual(canvas.fills.last(where: { $0 != .clear }), XColorValue(1, 1, 1, 0.1))
        bank.beginLearning(0)
        (_, canvas) = await draw(bank)
        XCTAssertEqual(canvas.fills.last(where: { $0 != .clear })?.opacity, 0.5)
        XCTAssertNotEqual(canvas.fills.last(where: { $0 != .clear }), tint.opacity(0.5))
    }

    // MARK: Gestures

    @XUIActor
    func testDraggingTheKnobMovesTheTargetThroughTheBank() async throws {
        let (host, bank, p) = try make()
        host.send(.controlChange(channel: 0, controller: 1, value: 64)); host.send(.controlChange(channel: 0, controller: 1, value: 70))
        let (render, _) = await draw(bank)
        let knob = try XCTUnwrap(render.dragGestures.first).rect
        var runtime = GestureRuntime()
        let grab = Point(x: knob.midX, y: knob.midY)
        let before = p.value
        _ = runtime.handle(.init(phase: .began, position: grab), in: render)
        XCTAssertEqual(p.value, before, "grabbing alone does not move it")
        _ = runtime.handle(.init(phase: .moved, position: Point(x: grab.x, y: grab.y - 30)), in: render)
        XCTAssertEqual(p.value, before + 0.2, accuracy: 1e-6)
        _ = runtime.handle(.init(phase: .moved, position: Point(x: grab.x, y: grab.y + 500)), in: render)
        XCTAssertEqual(p.value, 0, "clamped at the start")
        _ = runtime.handle(.init(phase: .ended, position: grab), in: render)
        host.send(.controlChange(channel: 0, controller: 1, value: 127))
        XCTAssertEqual(p.value, 0, "the hand took the value, so the controller has to come back")
    }

    @XUIActor
    func testLabelTapShowsConfigurationAndLongPressTogglesLearningForTheSlot() async throws {
        let (_, bank, _) = try make()
        let shown = Box()
        let (render, _) = await draw(bank, onShow: { shown.count += 1 })
        let onLabel = Point(x: 28, y: 56 + 2 + 14)
        var runtime = GestureRuntime()
        _ = runtime.handle(.init(phase: .began, position: onLabel, timestamp: 1), in: render)
        _ = runtime.handle(.init(phase: .ended, position: onLabel, timestamp: 1.1), in: render)
        XCTAssertEqual(shown.count, 1)
        XCTAssertNil(bank.learningSlot)
        _ = runtime.handle(.init(phase: .began, position: onLabel, timestamp: 5), in: render)
        _ = runtime.handle(.init(phase: .ended, position: onLabel, timestamp: 5.8), in: render)
        XCTAssertEqual(bank.learningSlot, 0)
        XCTAssertEqual(shown.count, 1, "a long press is not also a tap")
        _ = runtime.handle(.init(phase: .began, position: onLabel, timestamp: 9), in: render)
        _ = runtime.handle(.init(phase: .ended, position: onLabel, timestamp: 9.9), in: render)
        XCTAssertNil(bank.learningSlot, "and again to stop")
    }

    @XUIActor
    func testARowHasOneKnobPerSlotAndTellsWhichLabelWasTapped() async throws {
        let (_, bank, _) = try make()
        let tapped = Box()
        let canvas = Recorder()
        let row = LiveFaderKnobRow(bank: bank, tint: tint, size: 56, spacing: 6) { slot in tapped.count = slot + 10 }
        let render = await LayoutHost(canvas: Size(width: 56 * 3 + 12, height: 90)).render(row, into: canvas)
        XCTAssertEqual(canvas.texts, ["Gain", "0.500", "empty", "empty"])
        let secondLabel = Point(x: 56 + 6 + 28, y: 56 + 2 + 14)
        var runtime = GestureRuntime()
        _ = runtime.handle(.init(phase: .began, position: secondLabel, timestamp: 1), in: render)
        _ = runtime.handle(.init(phase: .ended, position: secondLabel, timestamp: 1.1), in: render)
        XCTAssertEqual(tapped.count, 11)
    }
}
