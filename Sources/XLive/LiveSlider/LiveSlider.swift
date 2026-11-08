import XUI

/// The numbers behind the bar, apart from any drawing: where the thumb sits, how far the fill
/// reaches, and what a drag does. Width and height are the bar's own box.
public struct LiveSliderGeometry: Equatable, Sendable {
    public static let thumbAspect = 1.414
    public static let barThickness = 4.0

    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width.isFinite ? max(0, width) : 0
        self.height = height.isFinite ? max(0, height) : 0
    }

    public var thumbWidth: Double { height * Self.thumbAspect }
    /// How far the thumb's centre can move.
    public var travel: Double { max(0, width - thumbWidth) }
    /// The pale track behind the fill.
    public var trackWidth: Double { max(0, min(1000, width - thumbWidth - 2)) }

    public func thumbCenterX(_ normal: Double) -> Double { clamp(normal) * travel + thumbWidth / 2 }
    public func fillWidth(_ normal: Double) -> Double { clamp(normal) * travel }
    public var fillStartX: Double { thumbWidth / 2 }

    /// The position a relative drag reaches: where it started plus the distance moved, in
    /// fractions of the thumb's travel, so the thumb stays under the finger. Nil when there is
    /// no room to move. The result is not clamped; the parameter's range does that.
    public func draggedNormal(start: Double, translation: Double) -> Double? {
        guard travel > 0, start.isFinite, translation.isFinite else { return nil }
        return start + translation / travel
    }

    private func clamp(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0 }
}

/// A slider row in the style of the 100VJ `Animatable`: a label button on the left and the bar
/// on the right.
///
/// - **Label** (name over current value): tap calls `onShowConfiguration`; long press toggles
///   MIDI learn. Its background shows the MIDI state — plain when none, tinted when assigned,
///   a hue-shifted tint while learning.
/// - **Bar**: a tap switches automation on or off. The thumb moves the value by a relative
///   drag, so grabbing it never makes it jump. While automation is on the thumb is hidden, the
///   fill is dimmed, and the bar cannot be dragged.
///
/// It reads the parameter every time it is declared and changes it through the parameter's own
/// methods, so it keeps no state of its own. Long press needs a host that sends pointer
/// timestamps (see `LongPressGesture`).
public struct LiveSlider: XView, Sendable {
    private let parameter: LiveParameter
    private let title: String?
    private let tint: XColorValue
    private let height: Double
    private let labelWidth: Double
    private let onShowConfiguration: (@Sendable () -> Void)?

    /// - Parameters:
    ///   - title: Replaces the parameter's label.
    ///   - onShowConfiguration: Called when the label is tapped. The host owns the sheet.
    public init(parameter: LiveParameter, title: String? = nil,
                tint: XColorValue = XColorValue(0.25, 0.6, 1), height: Double = 36, labelWidth: Double = 62,
                onShowConfiguration: (@Sendable () -> Void)? = nil) {
        self.parameter = parameter
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

    // MARK: Label

    private var label: some XView {
        let state = parameter.state
        let parameter = self.parameter
        let onShow = onShowConfiguration
        return ZStack {
            RoundedRectangle(cornerRadius: 8, fill: labelColor(state.midiState))
            VStack(alignment: .leading, spacing: 0) {
                Text(title ?? state.label, size: 10, color: tint.opacity(0.9))
                    .lineLimit(1)
                    .frame(width: max(0, labelWidth - 8), alignment: .leading)
                Text(state.valueText, size: 10, color: XColorValue.white.opacity(0.9))
                    .font(.numeric)
                    .frame(width: max(0, labelWidth - 8), alignment: .leading)
            }
        }
        .frame(width: labelWidth, height: height)
        .onTapGesture { onShow?() }
        .onLongPressGesture { parameter.toggleLearning() }
    }

    private func labelColor(_ midi: LiveMIDIState) -> XColorValue {
        switch midi {
        case .none: return XColorValue(1, 1, 1, 0.1)
        case .assigned: return tint.opacity(0.5)
        case .learning: return Self.hueRotated(tint, degrees: 120).opacity(0.5)
        }
    }

    // MARK: Bar

    private var bar: some XView {
        let state = parameter.state
        let parameter = self.parameter
        let automated = state.isAutomated
        let normal = state.normalizedValue
        let fillColor = tint.opacity(automated ? 0.4 : 1)
        return GeometryReader { geo in
            let g = LiveSliderGeometry(width: geo.width, height: geo.height)
            let centerY = geo.height / 2
            ZStack(alignment: .topLeading) {
                // Fills the whole bar, so a tap anywhere on it counts: the pieces below are
                // positioned and would otherwise shrink the tappable area to their extent.
                Rectangle(fill: .clear)
                RoundedRectangle(cornerRadius: 2, fill: XColorValue(1, 1, 1, 0.25))
                    .frame(width: g.trackWidth, height: LiveSliderGeometry.barThickness)
                    .position(x: geo.width / 2, y: centerY)
                RoundedRectangle(cornerRadius: 2, fill: fillColor)
                    .frame(width: g.fillWidth(normal), height: LiveSliderGeometry.barThickness)
                    .position(x: g.fillStartX + g.fillWidth(normal) / 2, y: centerY)
                if !automated {
                    thumb(g)
                        .gesture(DragGesture(minimumDistance: 0.1).onChanged { drag in
                            // `normal` is the value when this was declared, which is the value at
                            // the start of the drag: the runtime keeps the drag's first declaration.
                            guard let next = g.draggedNormal(start: normal, translation: drag.translation.x) else { return }
                            parameter.setNormalizedManualValue(next)
                        })
                        .position(x: g.thumbCenterX(normal), y: centerY)
                }
            }
            .onTapGesture { parameter.toggleAutomation() }
        }
    }

    private func thumb(_ g: LiveSliderGeometry) -> some XView {
        ZStack {
            RoundedRectangle(cornerRadius: g.height / 2, fill: XColorValue(1, 1, 1, 0.168))
            Rectangle(fill: .white).frame(width: 1, height: max(0, g.height - 16))
        }
        .frame(width: g.thumbWidth, height: g.height)
    }

    // MARK: Colour

    /// Rotates the hue of a colour, keeping saturation, brightness and opacity.
    static func hueRotated(_ color: XColorValue, degrees: Double) -> XColorValue {
        let r = color.red, g = color.green, b = color.blue
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        guard delta > 0 else { return color }   // grey: no hue to turn
        var hue: Double
        if maxC == r { hue = (g - b) / delta }
        else if maxC == g { hue = 2 + (b - r) / delta }
        else { hue = 4 + (r - g) / delta }
        hue = (hue * 60 + degrees).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let saturation = delta / maxC, value = maxC
        let sector = hue / 60, i = Int(sector) % 6, f = sector - Double(Int(sector))
        let p = value * (1 - saturation), q = value * (1 - saturation * f), t = value * (1 - saturation * (1 - f))
        let rgb: (Double, Double, Double)
        switch i {
        case 0: rgb = (value, t, p)
        case 1: rgb = (q, value, p)
        case 2: rgb = (p, value, t)
        case 3: rgb = (p, q, value)
        case 4: rgb = (t, p, value)
        default: rgb = (value, p, q)
        }
        return XColorValue(rgb.0, rgb.1, rgb.2, color.opacity)
    }
}
