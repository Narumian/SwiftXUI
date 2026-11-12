import XUI

/// One fader of a `LiveFaderBank` as a slider row, in the style of `LiveSlider`: the label on the
/// left, the bar on the right.
///
/// - **Label** (the target's name over its value, or dashes with no target): tap calls
///   `onShowConfiguration`; long press starts MIDI learn for this slot, or cancels it. The
///   background shows the slot's MIDI state like `LiveSlider`'s.
/// - **Bar**: it shows the target's own value, so it is right whoever moved the value last. The
///   thumb moves the value by a relative drag (`LiveFaderBank.move`). A target that is automated
///   (locked) dims the bar and takes no drag, and so does a slot with no target.
/// - **Waiting mark**: a thin line in the tint where the MIDI controller is, drawn only while
///   it has not reached the value; moving the controller to the thumb picks the value up.
///
/// Like `LiveSlider` it reads the bank every time it paints and changes it only through the
/// bank's methods, so its fixed layout can be reused. Long press needs a host that sends pointer
/// timestamps (see `LongPressGesture`).
public struct LiveFaderSlider: XView, Sendable {
    private let bank: LiveFaderBank
    private let slot: Int
    private let title: String?
    private let tint: XColorValue
    private let height: Double
    private let labelWidth: Double
    private let onShowConfiguration: (@Sendable () -> Void)?

    public init(bank: LiveFaderBank, slot: Int, title: String? = nil,
                tint: XColorValue = XColorValue(0.25, 0.6, 1), height: Double = 36, labelWidth: Double = 62,
                onShowConfiguration: (@Sendable () -> Void)? = nil) {
        self.bank = bank
        self.slot = slot
        self.title = title
        self.tint = tint
        self.height = height.isFinite ? max(8, height) : 36
        self.labelWidth = labelWidth.isFinite ? max(0, labelWidth) : 62
        self.onShowConfiguration = onShowConfiguration
    }

    public var body: some XView {
        HStack(spacing: 4) {
            label
            bar
        }
        .frame(height: height)
    }

    private var label: some XView {
        let bank = self.bank, slot = self.slot, tint = self.tint
        let onShow = onShowConfiguration
        return DrawLayer { rect, context in
            let target = bank.target(slot)?.state
            LiveSlider.drawLabel(in: rect, context, title: title ?? target?.label ?? "—", value: target?.valueText ?? "—",
                                 fill: LiveSlider.labelColor(bank.midiState(slot), tint: tint), tint: tint)
        }
        .frame(width: labelWidth, height: height)
        .onTapGesture { onShow?() }
        .onLongPressGesture {
            if bank.learningSlot == slot { bank.cancelLearning() } else { bank.beginLearning(slot) }
        }
    }

    private var bar: some XView {
        let bank = self.bank, slot = self.slot, tint = self.tint
        return DrawLayer { rect, context in
            let target = bank.target(slot)
            let state = target?.state
            let normal = state?.normalizedValue ?? 0
            let locked = state == nil || state?.isAutomated == true
            let g = LiveSliderGeometry(width: rect.width, height: rect.height)
            let thickness = LiveSliderGeometry.barThickness
            let trackY = rect.midY - thickness / 2
            let canvas = context.canvas
            canvas.fillRect(rect, color: .clear)
            canvas.fillRoundedRect(Rect(x: rect.midX - g.trackWidth / 2, y: trackY, width: g.trackWidth, height: thickness),
                                   cornerRadius: 2, color: XColorValue(1, 1, 1, 0.25))
            canvas.fillRoundedRect(Rect(x: rect.x + g.fillStartX, y: trackY, width: g.fillWidth(normal), height: thickness),
                                   cornerRadius: 2, color: tint.opacity(locked ? 0.4 : 1))
            if bank.isWaiting(slot), let position = bank.controlPosition(slot) {
                let x = rect.x + g.thumbCenterX(position)
                canvas.fillRect(Rect(x: x - 1, y: rect.y + 4, width: 2, height: max(0, rect.height - 8)), color: tint.opacity(0.9))
            }
            if !locked {
                let thumb = Rect(x: rect.x + g.thumbCenterX(normal) - g.thumbWidth / 2,
                                 y: rect.y, width: g.thumbWidth, height: g.height)
                canvas.fillRoundedRect(thumb, cornerRadius: g.height / 2, color: XColorValue(1, 1, 1, 0.168))
                let lineHeight = max(0, g.height - 16)
                canvas.fillRect(Rect(x: thumb.midX - 0.5, y: thumb.midY - lineHeight / 2, width: 1, height: lineHeight), color: .white)
                context.addDragGesture(thumb, gesture: DragGesture(minimumDistance: 0.1).onChanged { drag in
                    guard let next = g.draggedNormal(start: normal, translation: drag.translation.x) else { return }
                    bank.move(slot, to: next)
                })
            }
        }
    }
}
