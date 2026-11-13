import XCTest
@testable import XLive
import XUI

private final class Recorder: XCanvas {
    struct Stroke { let points: Int; let color: XColorValue; let lineWidth: Double }
    var fills: [XColorValue] = []
    var strokes: [Stroke] = []
    var ellipses = 0
    var texts: [String] = []
    var textColors: [XColorValue] = []
    func fillRect(_ rect: Rect, color: XColorValue) { fills.append(color) }
    func fillRoundedRect(_ rect: Rect, cornerRadius: Double, color: XColorValue) { fills.append(color) }
    func fillEllipse(in rect: Rect, color: XColorValue) { ellipses += 1 }
    func strokePath(_ path: Path, in rect: Rect, color: XColorValue, lineWidth: Double) {
        strokes.append(Stroke(points: path.elements.count, color: color, lineWidth: lineWidth))
    }
    func drawText(_ string: String, in rect: Rect, fontSize: Double, font: TextFont, color: XColorValue,
                  alignment: HorizontalAlignment, outline: TextOutline?) { texts.append(string); textColors.append(color) }
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
        XCTAssertEqual(canvas.texts, ["Gain"], "just the name while nothing holds the knob")
        XCTAssertEqual(canvas.strokes.count, 5, "hairline, track, value arc, pointer halo, pointer — and no waiting mark")
        XCTAssertEqual(canvas.strokes[2].color.opacity, 1)
        XCTAssertEqual(canvas.strokes.last?.color, XColorValue.white)
        XCTAssertNotNil(render.dragGestures.first)
        p.setManualValue(0)
        let (_, empty) = await draw(bank)
        XCTAssertEqual(empty.strokes.count, 4, "a value at the very start has no arc")
        p.setManualValue(0.5)
        bank.hold(0)
        let (_, held) = await draw(bank)
        XCTAssertEqual(held.texts, ["0.500"], "the value takes the name's place while the knob is held")
        bank.letGo(0)
        let (_, after) = await draw(bank)
        XCTAssertEqual(after.texts, ["Gain"])
    }

    @XUIActor
    func testASlotWithoutATargetIsEmptyAndCannotBeTurned() async throws {
        let (_, bank, _) = try make()
        bank.setTargets([nil, nil, nil])
        let (render, canvas) = await draw(bank)
        XCTAssertEqual(canvas.texts, ["empty"])
        XCTAssertTrue(render.dragGestures.isEmpty)
        XCTAssertEqual(canvas.strokes.count, 2, "the hairline and the track only")
    }

    @XUIActor
    func testAnAutomatedTargetDimsTheKnobAndTakesNoDrag() async throws {
        let (_, bank, p) = try make()
        p.edit { $0.setSource(.lfo); $0.setAutomation(on: true) }
        let (render, canvas) = await draw(bank)
        XCTAssertTrue(render.dragGestures.isEmpty)
        XCTAssertEqual(canvas.strokes[2].color.opacity, 0.4, accuracy: 1e-9)
        XCTAssertEqual(canvas.strokes.last?.color.opacity ?? 1, 0.4, accuracy: 1e-9, "and so does the pointer")
    }

    @XUIActor
    func testAWaitingControllerIsMarkedOutsideTheRim() async throws {
        let (host, bank, _) = try make()
        host.send(.controlChange(channel: 0, controller: 1, value: 0))
        XCTAssertTrue(bank.isWaiting(0))
        let (_, waiting) = await draw(bank)
        XCTAssertEqual(waiting.strokes.count, 6)
        XCTAssertEqual(waiting.strokes.last?.color, tint.opacity(0.9))
        host.send(.controlChange(channel: 0, controller: 1, value: 64))
        let (_, held) = await draw(bank)
        XCTAssertEqual(held.strokes.count, 5)
    }

    @XUIActor
    func testLabelColourShowsTheSlotsMIDIState() async throws {
        let (_, bank, _) = try make()
        var (_, canvas) = await draw(bank)
        XCTAssertEqual(canvas.textColors.last, tint.opacity(0.9), "assigned: the tint")
        bank.unassign(0)
        (_, canvas) = await draw(bank)
        XCTAssertEqual(canvas.textColors.last, XColorValue(1, 1, 1, 0.55), "no controller: grey")
        bank.beginLearning(0)
        (_, canvas) = await draw(bank)
        XCTAssertEqual(canvas.textColors.last, .white, "learning: white")
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
        let onLabel = Point(x: 28, y: 7)
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
        XCTAssertEqual(canvas.texts, ["Gain", "empty", "empty"])
        let secondLabel = Point(x: 56 + 6 + 28, y: 7)
        var runtime = GestureRuntime()
        _ = runtime.handle(.init(phase: .began, position: secondLabel, timestamp: 1), in: render)
        _ = runtime.handle(.init(phase: .ended, position: secondLabel, timestamp: 1.1), in: render)
        XCTAssertEqual(tapped.count, 11)
    }

    @XUIActor
    func testARowWithColumnsWrapsIntoLines() async throws {
        let (_, bank, _) = try make()
        bank.setTargets([nil, nil, nil])
        let canvas = Recorder()
        let row = LiveFaderKnobRow(bank: bank, tint: tint, size: 56, spacing: 6, columns: 2)
        let render = await LayoutHost(canvas: Size(width: 56 * 2 + 6, height: 300)).render(row, into: canvas)
        XCTAssertEqual(canvas.texts.count, 3, "one label per slot")
        let tops = Set(render.tapGestures.map { $0.rect.minY })
        XCTAssertEqual(tops.count, 2, "two lines of two and one")
    }

    func testALongNameIsCutToTheColumnWithAnEllipsis() {
        let width: (String) -> Double = { Double($0.count) * 6 }
        XCTAssertEqual(LiveFaderKnob.ellipsised("Size", width: 30, widthOf: width), "Size")
        XCTAssertEqual(LiveFaderKnob.ellipsised("Segments", width: 30, widthOf: width), "Segm…")
        XCTAssertEqual(LiveFaderKnob.ellipsised("Segments", width: 3, widthOf: width), "…")
        XCTAssertEqual(LiveFaderKnob.ellipsised("Segments", width: .infinity, widthOf: width), "Segments")
    }
}
