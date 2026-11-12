import Foundation
import XUI

/// The numbers behind a knob, apart from any drawing. The knob sweeps 270°, from the lower left
/// round the top to the lower right. Angles are in degrees, clockwise on the screen, 0° pointing
/// right.
public struct LiveKnobGeometry: Equatable, Sendable {
    public static let startAngle = 135.0
    public static let sweep = 270.0
    /// How far a drag has to go to cross the whole range, in points.
    public static let dragDistance = 150.0

    public let center: Point
    public let radius: Double

    /// A knob filling the largest circle of the box, less `inset` for the rim's stroke.
    public init(width: Double, height: Double, inset: Double = 5) {
        let w = width.isFinite ? max(0, width) : 0, h = height.isFinite ? max(0, height) : 0
        center = Point(x: w / 2, y: h / 2)
        radius = max(0, min(w, h) / 2 - inset)
    }

    public static func angle(_ normal: Double) -> Double { startAngle + sweep * min(1, max(0, normal.isFinite ? normal : 0)) }

    public func point(_ normal: Double, radius r: Double, origin: Point = Point(x: 0, y: 0)) -> Point {
        let a = Self.angle(normal) * .pi / 180
        return Point(x: origin.x + center.x + cos(a) * r, y: origin.y + center.y + sin(a) * r)
    }

    /// A polyline along the rim from `from` to `to` (both 0...1), for stroking.
    public func arc(from: Double, to: Double, radius r: Double, origin: Point = Point(x: 0, y: 0)) -> [Point] {
        let lower = min(max(from, 0), 1), upper = min(max(to, 0), 1)
        let steps = max(1, Int((upper - lower) * 48))
        return (0...steps).map { point(lower + (upper - lower) * Double($0) / Double(steps), radius: r, origin: origin) }
    }

    /// Dragging up turns the knob up, relative to where it was grabbed. Nil for a bad number.
    public static func draggedNormal(start: Double, translationY: Double) -> Double? {
        guard start.isFinite, translationY.isFinite else { return nil }
        return start - translationY / dragDistance
    }
}

/// One fader of a `LiveFaderBank` as a knob with its name and value underneath. A row of them
/// is the common fader laid out side by side (`LiveFaderKnobRow`).
///
/// - **Knob**: the arc shows the target's own value, so it is right whoever moved the value last.
///   Dragging up or down turns it, relative to where it was grabbed (`LiveFaderBank.move`). A
///   target that is automated (locked), or no target, dims it and takes no drag.
/// - **Waiting mark**: a short tick outside the rim where the MIDI controller is, drawn only
///   while the controller has not reached the value yet.
/// - **Label**: tap calls `onShowConfiguration`; long press starts MIDI learn for this slot, or
///   cancels it. The background shows the slot's MIDI state like `LiveSlider`'s label.
///
/// It reads the bank every time it paints, so its fixed layout can be reused. Long press needs a
/// host that sends pointer timestamps (see `LongPressGesture`).
public struct LiveFaderKnob: XView, Sendable {
    private let bank: LiveFaderBank
    private let slot: Int
    private let title: String?
    private let tint: XColorValue
    private let size: Double
    private let labelHeight: Double
    private let onShowConfiguration: (@Sendable () -> Void)?

    public init(bank: LiveFaderBank, slot: Int, title: String? = nil,
                tint: XColorValue = XColorValue(0.25, 0.6, 1), size: Double = 56, labelHeight: Double = 32,
                onShowConfiguration: (@Sendable () -> Void)? = nil) {
        self.bank = bank
        self.slot = slot
        self.title = title
        self.tint = tint
        self.size = size.isFinite ? max(24, size) : 56
        self.labelHeight = labelHeight.isFinite ? max(8, labelHeight) : 32
        self.onShowConfiguration = onShowConfiguration
    }

    public var body: some XView {
        VStack(spacing: 2) {
            knob
            label
        }
        .frame(width: size)
    }

    private var knob: some XView {
        let bank = self.bank, slot = self.slot, tint = self.tint
        return DrawLayer { rect, context in
            let state = bank.target(slot)?.state
            let normal = state?.normalizedValue ?? 0
            let locked = state == nil || state?.isAutomated == true
            let g = LiveKnobGeometry(width: rect.width, height: rect.height)
            let canvas = context.canvas
            let origin = Point(x: rect.x, y: rect.y)
            canvas.fillRect(rect, color: .clear)
            guard g.radius > 0 else { return }
            func stroke(_ points: [Point], _ color: XColorValue, _ width: Double) {
                guard let box = Self.bounds(points) else { return }
                canvas.strokePath(Path(points: points, closed: false), in: box, color: color, lineWidth: width)
            }
            stroke(g.arc(from: 0, to: 1, radius: g.radius, origin: origin), XColorValue(1, 1, 1, 0.25), 3)
            if normal > 0 {
                stroke(g.arc(from: 0, to: normal, radius: g.radius, origin: origin), tint.opacity(locked ? 0.4 : 1), 3)
            }
            let face = g.radius - 6
            canvas.fillEllipse(in: Rect(x: rect.x + g.center.x - face, y: rect.y + g.center.y - face, width: face * 2, height: face * 2),
                               color: XColorValue(1, 1, 1, 0.1))
            if state != nil {
                stroke([g.point(normal, radius: face * 0.3, origin: origin), g.point(normal, radius: face * 0.9, origin: origin)],
                       XColorValue.white.opacity(locked ? 0.4 : 1), 2)
            }
            if bank.isWaiting(slot), let position = bank.controlPosition(slot) {
                stroke([g.point(position, radius: g.radius + 1, origin: origin), g.point(position, radius: g.radius + 5, origin: origin)],
                       tint.opacity(0.9), 2.5)
            }
            if !locked {
                context.addDragGesture(rect, gesture: DragGesture(minimumDistance: 0.1).onChanged { drag in
                    guard let next = LiveKnobGeometry.draggedNormal(start: normal, translationY: drag.translation.y) else { return }
                    bank.move(slot, to: next)
                })
            }
        }
        .frame(width: size, height: size)
    }

    /// A stroked path is scaled into the box it is given, so the box is the points' own bounds.
    private static func bounds(_ points: [Point]) -> Rect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return Rect(x: minX, y: minY, width: max(maxX - minX, 0.001), height: max(maxY - minY, 0.001))
    }

    private var label: some XView {
        let bank = self.bank, slot = self.slot, tint = self.tint
        let onShow = onShowConfiguration
        return DrawLayer { rect, context in
            let target = bank.target(slot)?.state
            LiveSlider.drawLabel(in: rect, context, title: title ?? target?.label ?? "empty", value: target?.valueText ?? "",
                                 fill: LiveSlider.labelColor(bank.midiState(slot), tint: tint), tint: tint)
        }
        .frame(width: size, height: labelHeight)
        .onTapGesture { onShow?() }
        .onLongPressGesture {
            if bank.learningSlot == slot { bank.cancelLearning() } else { bank.beginLearning(slot) }
        }
    }
}

/// The whole bank as a row of knobs, left to right in slot order.
public struct LiveFaderKnobRow: XView, Sendable {
    private struct Slot: Identifiable, Sendable { let id: Int }

    private let bank: LiveFaderBank
    private let tint: XColorValue
    private let size: Double
    private let spacing: Double
    private let onShowConfiguration: (@Sendable (Int) -> Void)?

    public init(bank: LiveFaderBank, tint: XColorValue = XColorValue(0.25, 0.6, 1), size: Double = 56, spacing: Double = 6,
                onShowConfiguration: (@Sendable (Int) -> Void)? = nil) {
        self.bank = bank
        self.tint = tint
        self.size = size
        self.spacing = spacing
        self.onShowConfiguration = onShowConfiguration
    }

    public var body: some XView {
        let bank = self.bank, tint = self.tint, size = self.size, onShow = onShowConfiguration
        return HStack(spacing: spacing) {
            ForEach((0..<bank.count).map { Slot(id: $0) }) { item in
                LiveFaderKnob(bank: bank, slot: item.id, tint: tint, size: size) { onShow?(item.id) }
            }
        }
    }
}
