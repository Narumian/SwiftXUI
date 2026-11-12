import XUI

/// Where the two lines of a slider or knob label go: the name over the value, inside a rounded box.
/// It is plain arithmetic on a rect and a text measure, so the drawing stays a handful of canvas
/// calls and the numbers can be tested apart from any renderer.
///
/// Both lines share one column, inset from the box by `horizontalPadding` so the text clears the
/// rounded corners; a line too wide for it is wrapped (the name is cut to one line). The block
/// of lines, with `lineGap` between name and value, is centred in the box.
struct LiveLabelLayout: Equatable {
    /// The box's corner radius. The text column starts this far in, which keeps it off the curve.
    static let cornerRadius = 8.0
    static let horizontalPadding = 8.0
    static let lineGap = 1.0
    static let fontSize = 10.0

    struct Line: Equatable {
        let text: String
        let rect: Rect
        let isTitle: Bool
    }

    let lines: [Line]

    init(title: String, value: String, in rect: Rect, measure: (String, Double, TextFont) -> Size) {
        let width = max(0, rect.width - 2 * Self.horizontalPadding)
        let titleSize = measure(title, Self.fontSize, .ui)
        let valueSize = measure(value, Self.fontSize, .numeric)
        let titleLines = Text.needsWrapping(title, natural: titleSize, maxWidth: width)
            ? Text.visibleLines(title, maxWidth: width, lineLimit: 1) { measure($0, Self.fontSize, .ui).width }
            : [title]
        let valueLines = value.isEmpty ? [] : Text.needsWrapping(value, natural: valueSize, maxWidth: width)
            ? Text.visibleLines(value, maxWidth: width, lineLimit: nil) { measure($0, Self.fontSize, .numeric).width }
            : [value]
        let gap = valueLines.isEmpty ? 0 : Self.lineGap
        let height = Double(titleLines.count) * titleSize.height + Double(valueLines.count) * valueSize.height + gap
        var y = rect.midY - height / 2
        let x = rect.x + Self.horizontalPadding
        var made: [Line] = []
        for text in titleLines {
            made.append(Line(text: text, rect: Rect(x: x, y: y, width: width, height: titleSize.height), isTitle: true))
            y += titleSize.height
        }
        y += gap
        for text in valueLines {
            made.append(Line(text: text, rect: Rect(x: x, y: y, width: width, height: valueSize.height), isTitle: false))
            y += valueSize.height
        }
        lines = made
    }
}
