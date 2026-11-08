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

private final class Counter: @unchecked Sendable { var count = 0 }

private let tint = XColorValue(0.25, 0.6, 1)

final class LiveSliderTests: XCTestCase {
    private func parameter(value: Double = 0.5, automated: Bool = false) throws -> LiveParameter {
        var state = try LiveParameterState(label: "Gain", value: value)
        if automated { state.setSource(.lfo); state.setAutomation(on: true) }
        return LiveParameter(state: state)
    }

    @XUIActor
    private func draw(_ p: LiveParameter, onShow: (@Sendable () -> Void)? = nil) async -> (RenderResult, Recorder) {
        let canvas = Recorder()
        let slider = LiveSlider(parameter: p, tint: tint, onShowConfiguration: onShow)
        let result = await LayoutHost(canvas: Size(width: 300, height: 36)).render(slider, into: canvas)
        return (result, canvas)
    }

    // MARK: Pure parts

    func testGeometry() {
        let g = LiveSliderGeometry(width: 234, height: 36)
        XCTAssertEqual(g.thumbWidth, 36 * 1.414, accuracy: 1e-9)
        XCTAssertEqual(g.travel, 234 - 36 * 1.414, accuracy: 1e-9)
        XCTAssertEqual(g.thumbCenterX(0), g.thumbWidth / 2, accuracy: 1e-9)
        XCTAssertEqual(g.thumbCenterX(1), 234 - g.thumbWidth / 2, accuracy: 1e-9)
        XCTAssertEqual(g.fillWidth(0.5), g.travel / 2, accuracy: 1e-9)
        XCTAssertEqual(g.fillWidth(7), g.travel, "clamped")
        XCTAssertEqual(g.trackWidth, 234 - g.thumbWidth - 2, accuracy: 1e-9)
        XCTAssertEqual(g.draggedNormal(start: 0.25, translation: g.travel / 2)!, 0.75, accuracy: 1e-9)
        XCTAssertNil(LiveSliderGeometry(width: 40, height: 36).draggedNormal(start: 0, translation: 5), "no room to move")
        XCTAssertNil(g.draggedNormal(start: .nan, translation: 1))
        XCTAssertEqual(LiveSliderGeometry(width: .nan, height: -4).width, 0)
        XCTAssertEqual(LiveSliderGeometry(width: 5000, height: 10).trackWidth, 1000, "the track is capped")
    }

    func testHueRotation() {
        let green = LiveSlider.hueRotated(XColorValue(1, 0, 0, 0.5), degrees: 120)
        XCTAssertEqual(green.red, 0, accuracy: 1e-9); XCTAssertEqual(green.green, 1, accuracy: 1e-9)
        XCTAssertEqual(green.blue, 0, accuracy: 1e-9); XCTAssertEqual(green.opacity, 0.5)
        let grey = XColorValue(0.4, 0.4, 0.4)
        XCTAssertEqual(LiveSlider.hueRotated(grey, degrees: 120), grey)
        let back = LiveSlider.hueRotated(LiveSlider.hueRotated(tint, degrees: 120), degrees: -120)
        XCTAssertEqual(back.red, tint.red, accuracy: 1e-9); XCTAssertEqual(back.blue, tint.blue, accuracy: 1e-9)
        let full = LiveSlider.hueRotated(tint, degrees: 360)
        XCTAssertEqual(full.green, tint.green, accuracy: 1e-9)
    }

    // MARK: Drawing

    @XUIActor
    func testLabelIsOnTheLeftAndTheBarOnTheRight() async throws {
        let p = try parameter(value: 0.5)
        let (render, canvas) = await draw(p)
        XCTAssertEqual(canvas.texts, ["Gain", "0.50000"])
        let label = canvas.fills[0]
        XCTAssertEqual(label.cornerRadius, 8)
        XCTAssertEqual(label.rect.width, 62, accuracy: 1e-9)
        let track = canvas.fills[2]
        XCTAssertEqual(track.cornerRadius, 2)
        XCTAssertGreaterThan(track.rect.x, label.rect.x + label.rect.width)
        XCTAssertEqual(track.rect.height, 4, accuracy: 1e-9)
        let thumb = try XCTUnwrap(render.dragGestures.first)
        XCTAssertEqual(thumb.rect.width, 36 * 1.414, accuracy: 1e-6)
    }

    @XUIActor
    func testAutomationDimsTheFillAndHidesTheThumb() async throws {
        let p = try parameter(automated: true)
        let (render, canvas) = await draw(p)
        XCTAssertTrue(render.dragGestures.isEmpty, "nothing to drag")
        XCTAssertEqual(canvas.fills.count, 4, "label, hit area, track, fill — no thumb")
        XCTAssertEqual(canvas.fills[3].color.opacity, 0.4, accuracy: 1e-9)
        let (_, manual) = await draw(try parameter())
        XCTAssertEqual(manual.fills[3].color.opacity, 1)
        XCTAssertEqual(manual.fills.count, 6, "label, hit area, track, fill, thumb, and its centre line")
    }

    @XUIActor
    func testLabelColourShowsTheMIDIState() async throws {
        let p = try parameter()
        var (_, canvas) = await draw(p)
        XCTAssertEqual(canvas.fills[0].color, XColorValue(1, 1, 1, 0.1))
        p.edit { $0.assign(try! LiveMIDIAddress(kind: .control, channel: 0, number: 1)) }
        (_, canvas) = await draw(p)
        XCTAssertEqual(canvas.fills[0].color, tint.opacity(0.5))
        p.toggleLearning()
        (_, canvas) = await draw(p)
        XCTAssertNotEqual(canvas.fills[0].color, tint.opacity(0.5))
        XCTAssertEqual(canvas.fills[0].color.opacity, 0.5)
    }

    // MARK: Gestures

    @XUIActor
    func testDraggingTheThumbMovesTheValueRelativelyWithoutAJump() async throws {
        let p = try parameter(value: 0.5)
        let (render, _) = await draw(p)
        let thumb = try XCTUnwrap(render.dragGestures.first).rect
        let travel = LiveSliderGeometry(width: 300 - 62 - 4, height: 36).travel
        var runtime = GestureRuntime()
        let grab = Point(x: thumb.x + 4, y: thumb.y + 18)      // off-centre on purpose
        _ = runtime.handle(.init(phase: .began, position: grab), in: render)
        XCTAssertEqual(p.value, 0.5, "grabbing alone does not move it")
        _ = runtime.handle(.init(phase: .moved, position: Point(x: grab.x + travel / 4, y: grab.y)), in: render)
        XCTAssertEqual(p.value, 0.75, accuracy: 1e-6)
        _ = runtime.handle(.init(phase: .moved, position: Point(x: grab.x - travel, y: grab.y)), in: render)
        XCTAssertEqual(p.value, 0, "clamped at the left end")
        _ = runtime.handle(.init(phase: .moved, position: Point(x: grab.x + travel * 3, y: grab.y)), in: render)
        XCTAssertEqual(p.value, 1, "and at the right end")
        _ = runtime.handle(.init(phase: .ended, position: Point(x: grab.x, y: grab.y)), in: render)
        XCTAssertFalse(p.state.automationIsOn, "a drag is not a tap")
    }

    @XUIActor
    func testTappingTheBarTurnsAutomationOnAndOff() async throws {
        let p = try parameter()
        p.edit { $0.setSource(.lfo) }
        var (render, canvas) = await draw(p)
        let track = canvas.fills[2].rect
        let away = Point(x: track.x + 3, y: track.y + 2)       // on the bar, away from the thumb
        var runtime = GestureRuntime()
        _ = runtime.handle(.init(phase: .began, position: away), in: render)
        _ = runtime.handle(.init(phase: .ended, position: away), in: render)
        XCTAssertTrue(p.state.isAutomated)
        (render, canvas) = await draw(p)
        XCTAssertTrue(render.dragGestures.isEmpty)
        _ = runtime.handle(.init(phase: .began, position: away), in: render)
        _ = runtime.handle(.init(phase: .ended, position: away), in: render)
        XCTAssertFalse(p.state.isAutomated)
    }

    @XUIActor
    func testTappingTheThumbWithoutDraggingAlsoToggles() async throws {
        let p = try parameter()
        p.edit { $0.setSource(.lfo) }
        let (render, _) = await draw(p)
        let thumb = try XCTUnwrap(render.dragGestures.first).rect
        let centre = Point(x: thumb.x + thumb.width / 2, y: thumb.y + thumb.height / 2)
        var runtime = GestureRuntime()
        _ = runtime.handle(.init(phase: .began, position: centre), in: render)
        _ = runtime.handle(.init(phase: .ended, position: centre), in: render)
        XCTAssertTrue(p.state.automationIsOn)
        XCTAssertEqual(p.value, 0.5)
    }

    @XUIActor
    func testLabelTapShowsConfigurationAndLongPressTogglesLearning() async throws {
        let p = try parameter()
        let shown = Counter()
        let (render, _) = await draw(p, onShow: { shown.count += 1 })
        let onLabel = Point(x: 20, y: 18)
        var runtime = GestureRuntime()
        _ = runtime.handle(.init(phase: .began, position: onLabel, timestamp: 1), in: render)
        _ = runtime.handle(.init(phase: .ended, position: onLabel, timestamp: 1.1), in: render)
        XCTAssertEqual(shown.count, 1)
        XCTAssertFalse(p.state.isLearning)

        _ = runtime.handle(.init(phase: .began, position: onLabel, timestamp: 5), in: render)
        _ = runtime.handle(.init(phase: .ended, position: onLabel, timestamp: 5.8), in: render)
        XCTAssertEqual(shown.count, 1, "a long press is not also a tap")
        XCTAssertTrue(p.state.isLearning)
        XCTAssertEqual(p.state.midiState, .learning)

        _ = runtime.handle(.init(phase: .began, position: onLabel, timestamp: 9), in: render)
        _ = runtime.handle(.init(phase: .ended, position: onLabel, timestamp: 9.9), in: render)
        XCTAssertFalse(p.state.isLearning, "and again to stop")
    }

    @XUIActor
    func testTitleOverridesTheLabelAndAMissingCallbackIsHarmless() async throws {
        let p = try parameter()
        let canvas = Recorder()
        let result = await LayoutHost(canvas: Size(width: 300, height: 36))
            .render(LiveSlider(parameter: p, title: "Mix"), into: canvas)
        XCTAssertEqual(canvas.texts.first, "Mix")
        var runtime = GestureRuntime()
        _ = runtime.handle(.init(phase: .began, position: Point(x: 20, y: 18)), in: result)
        _ = runtime.handle(.init(phase: .ended, position: Point(x: 20, y: 18)), in: result)
    }
}
