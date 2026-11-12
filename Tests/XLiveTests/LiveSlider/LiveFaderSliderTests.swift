import XCTest
@testable import XLive
import XUI

private final class Recorder: XCanvas {
    struct Fill { let rect: Rect; let cornerRadius: Double; let color: XColorValue }
    var fills: [Fill] = []
    var texts: [String] = []
    func fillRect(_ rect: Rect, color: XColorValue) { fills.append(Fill(rect: rect, cornerRadius: 0, color: color)) }
    func fillRoundedRect(_ rect: Rect, cornerRadius: Double, color: XColorValue) {
        fills.append(Fill(rect: rect, cornerRadius: cornerRadius, color: color))
    }
    func drawText(_ string: String, in rect: Rect, fontSize: Double, font: TextFont, color: XColorValue,
                  alignment: HorizontalAlignment, outline: TextOutline?) { texts.append(string) }
}

private let tint = XColorValue(0.25, 0.6, 1)

final class LiveFaderSliderTests: XCTestCase {
    private func address(_ n: UInt8) -> LiveMIDIAddress { try! LiveMIDIAddress(kind: .control, channel: 0, number: n) }

    /// A bank of one fader on controller 1 whose target ("Gain") is 0.5 of 0...1.
    private func make(host: LiveParameterHost? = nil) throws -> (LiveFaderBank, LiveParameter) {
        let host = host ?? LiveParameterHost()
        let p = host.add(try LiveParameterState(label: "Gain", value: 0.5))
        let bank = LiveFaderBank(count: 1, environment: host)
        bank.assign(address(1), to: 0)
        bank.setTargets([p])
        return (bank, p)
    }

    @XUIActor
    private func draw(_ bank: LiveFaderBank, onShow: (@Sendable () -> Void)? = nil) async -> (RenderResult, Recorder) {
        let canvas = Recorder()
        let view = LiveFaderSlider(bank: bank, slot: 0, tint: tint, onShowConfiguration: onShow)
        return (await LayoutHost(canvas: Size(width: 300, height: 36)).render(view, into: canvas), canvas)
    }

    @XUIActor
    func testItShowsTheTargetsNameValueAndThumb() async throws {
        let (bank, p) = try make()
        let (render, canvas) = await draw(bank)
        XCTAssertEqual(canvas.texts, ["Gain", "0.50000"])
        XCTAssertEqual(canvas.fills.count, 6, "label, hit area, track, fill, thumb, and its centre line")
        XCTAssertEqual(canvas.fills[3].color.opacity, 1)
        XCTAssertNotNil(render.dragGestures.first)
        p.setManualValue(0.9)       // moved by something else: the bar follows
        let (_, again) = await draw(bank)
        XCTAssertEqual(again.texts, ["Gain", "0.90000"])
    }

    @XUIActor
    func testASlotWithoutATargetIsEmptyAndCannotBeDragged() async throws {
        let (bank, _) = try make()
        bank.setTargets([nil])
        let (render, canvas) = await draw(bank)
        XCTAssertEqual(canvas.texts, ["—", "—"])
        XCTAssertTrue(render.dragGestures.isEmpty)
        XCTAssertEqual(canvas.fills.count, 4)
    }

    @XUIActor
    func testAnAutomatedTargetDimsTheFaderAndTakesNoDrag() async throws {
        let (bank, p) = try make()
        p.edit { $0.setSource(.lfo); $0.setAutomation(on: true) }
        let (render, canvas) = await draw(bank)
        XCTAssertTrue(render.dragGestures.isEmpty)
        XCTAssertEqual(canvas.fills[3].color.opacity, 0.4, accuracy: 1e-9)
    }

    @XUIActor
    func testLabelColourShowsTheSlotsMIDIState() async throws {
        let (bank, _) = try make()
        var (_, canvas) = await draw(bank)
        XCTAssertEqual(canvas.fills[0].color, tint.opacity(0.5))
        bank.unassign(0)
        (_, canvas) = await draw(bank)
        XCTAssertEqual(canvas.fills[0].color, XColorValue(1, 1, 1, 0.1))
        bank.beginLearning(0)
        (_, canvas) = await draw(bank)
        XCTAssertNotEqual(canvas.fills[0].color, tint.opacity(0.5))
        XCTAssertEqual(canvas.fills[0].color.opacity, 0.5)
    }

    @XUIActor
    func testAWaitingControllerIsMarkedWhereItIs() async throws {
        let host = LiveParameterHost()
        let (bank, _) = try make(host: host)
        host.send(.controlChange(channel: 0, controller: 1, value: 0))        // far from 0.5: waiting
        XCTAssertTrue(bank.isWaiting(0))
        let (_, waiting) = await draw(bank)
        XCTAssertEqual(waiting.fills.count, 7, "the mark sits between the fill and the thumb")
        let mark = waiting.fills[4]
        XCTAssertEqual(mark.rect.width, 2)
        let g = LiveSliderGeometry(width: 300 - 62 - 4, height: 36)
        XCTAssertEqual(mark.rect.midX, waiting.fills[1].rect.x + g.thumbCenterX(0), accuracy: 1e-6, "at the controller's position")
        host.send(.controlChange(channel: 0, controller: 1, value: 64))       // picks the value up
        let (_, held) = await draw(bank)
        XCTAssertEqual(held.fills.count, 6)
    }

    @XUIActor
    func testDraggingTheThumbMovesTheTargetThroughTheBank() async throws {
        let host = LiveParameterHost()
        let (bank, p) = try make(host: host)
        host.send(.controlChange(channel: 0, controller: 1, value: 64))
        host.send(.controlChange(channel: 0, controller: 1, value: 70))       // the controller holds the value
        let (render, _) = await draw(bank)
        let thumb = try XCTUnwrap(render.dragGestures.first).rect
        let travel = LiveSliderGeometry(width: 300 - 62 - 4, height: 36).travel
        var runtime = GestureRuntime()
        let grab = Point(x: thumb.x + 4, y: thumb.y + 18)
        let before = p.value
        _ = runtime.handle(.init(phase: .began, position: grab), in: render)
        XCTAssertEqual(p.value, before, "grabbing alone does not move it")
        _ = runtime.handle(.init(phase: .moved, position: Point(x: grab.x - travel / 4, y: grab.y)), in: render)
        XCTAssertEqual(p.value, before - 0.25, accuracy: 1e-6)
        _ = runtime.handle(.init(phase: .ended, position: grab), in: render)
        host.send(.controlChange(channel: 0, controller: 1, value: 127))
        XCTAssertEqual(p.value, before - 0.25, accuracy: 1e-6, "the hand took the value, so the controller must come back")
    }

    @XUIActor
    func testLabelTapShowsConfigurationAndLongPressTogglesLearningForTheSlot() async throws {
        let (bank, _) = try make()
        let shown = Box()
        let (render, _) = await draw(bank, onShow: { shown.count += 1 })
        let onLabel = Point(x: 20, y: 18)
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

    private final class Box: @unchecked Sendable { var count = 0 }
}
