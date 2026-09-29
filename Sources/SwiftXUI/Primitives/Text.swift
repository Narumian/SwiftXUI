import Foundation

public enum TextFont: Hashable, Sendable {
    case ui
    case numeric
    case display
}

public struct TextOutline: Hashable, Sendable {
    public var color: XColorValue
    public var width: Double

    public init(color: XColorValue = XColorValue(0.05, 0.04, 0.07), width: Double = 3) {
        self.color = color
        self.width = width
    }
}

/// A run of text that wraps like SwiftUI's `Text`: given an unconstrained
/// width it stays on one line; offered a finite width narrower than its
/// content (typically via `.frame(maxWidth:)` or a parent that proposes one),
/// it word-wraps, breaking CJK text per character since it carries no spaces
/// to wrap on. `.lineLimit(_:)` caps the line count, ellipsising the last
/// visible line (SwiftUI's default `.tail` truncation).
public struct Text: XView, _PrimitiveXView {
    public typealias Body = Never

    var string: String
    var fontSize: Double
    var font: TextFont
    var color: XColorValue
    var alignment: HorizontalAlignment
    var outline: TextOutline?
    var lineLimit: Int?

    public init(_ string: String, size: Double = 17, color: XColorValue = .black) {
        self.string = string
        self.fontSize = size
        self.font = .ui
        self.color = color
        self.alignment = .leading
        self.outline = nil
        self.lineLimit = nil
    }

    public func font(size: Double) -> Text {
        var copy = self
        copy.fontSize = size
        return copy
    }

    public func font(_ font: TextFont) -> Text {
        var copy = self
        copy.font = font
        return copy
    }

    public func foregroundColor(_ color: XColorValue) -> Text {
        var copy = self
        copy.color = color
        return copy
    }

    /// How the glyphs sit inside whatever box layout gives this text (only
    /// visible once the text is stretched wider than its content, e.g. by
    /// `.frame(maxWidth: .infinity)`).
    public func multilineTextAlignment(_ alignment: HorizontalAlignment) -> Text {
        var copy = self
        copy.alignment = alignment
        return copy
    }

    public func outline(color: XColorValue = XColorValue(0.05, 0.04, 0.07), width: Double = 3) -> Text {
        var copy = self
        copy.outline = TextOutline(color: color, width: width)
        return copy
    }

    /// Caps the number of lines; `nil` (the default) never truncates. A run
    /// past the limit is dropped and the last visible line ends in "…".
    public func lineLimit(_ limit: Int?) -> Text {
        var copy = self
        copy.lineLimit = limit
        return copy
    }

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let node = LayoutNode(layout: TextLayout(string: string, fontSize: fontSize, font: font, lineLimit: lineLimit))
        let (string, fontSize, font, color, alignment, outline, lineLimit) =
            (string, fontSize, font, color, alignment, outline, lineLimit)
        node.draw = { rect, context in
            let measure = context.environment.measureText
            // `sizeThatFits` already decided single-line vs. wrapped, hugging to
            // the widest resulting line either way — so re-deriving that same
            // wrap from `rect.width` here reproduces its exact lines without a
            // second cache (every line it kept is by construction no wider than
            // that width), and costs the same one extra `measureText` call as
            // before when nothing needs to wrap.
            let natural = measure(string, fontSize, font)
            let lines = Text.needsWrapping(string, natural: natural, maxWidth: rect.width)
                ? Text.visibleLines(string, maxWidth: rect.width, lineLimit: lineLimit) { measure($0, fontSize, font).width }
                : [string]
            for (index, line) in lines.enumerated() {
                let lineRect = Rect(x: rect.x, y: rect.y + Double(index) * natural.height,
                                    width: rect.width, height: natural.height)
                context.canvas.drawText(
                    line,
                    in: lineRect,
                    fontSize: fontSize,
                    font: font,
                    color: color,
                    alignment: alignment,
                    outline: outline
                )
            }
        }
        return [node]
    }

    /// True for a Unicode scalar that stands on its own for wrapping — CJK
    /// text carries no spaces, so each such character is its own wrap unit;
    /// everything else only wraps on spaces, as in SwiftUI's default word wrap.
    private static func isStandaloneBreakable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK symbols & punctuation
             0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK unified ideographs extension A
             0x4E00...0x9FFF,   // CJK unified ideographs
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFF00...0xFFEF:   // halfwidth/fullwidth forms
            true
        default:
            false
        }
    }

    private static func isStandaloneBreakable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(isStandaloneBreakable)
    }

    /// One wrap unit, with whether the source text had a space before it (so
    /// a line break can drop that space without disturbing real spacing).
    private struct Token { var text: String; var spaceBefore: Bool }

    private static func tokenize(_ paragraph: Substring) -> [Token] {
        var tokens: [Token] = []
        var word = ""
        var wordSpaceBefore = false
        var pendingSpace = false
        func flushWord() {
            guard !word.isEmpty else { return }
            tokens.append(Token(text: word, spaceBefore: wordSpaceBefore))
            word = ""
        }
        for character in paragraph {
            if character == " " {
                flushWord()
                pendingSpace = true
            } else if isStandaloneBreakable(character) {
                flushWord()
                tokens.append(Token(text: String(character), spaceBefore: pendingSpace))
                pendingSpace = false
            } else {
                if word.isEmpty { wordSpaceBefore = pendingSpace; pendingSpace = false }
                word.append(character)
            }
        }
        flushWord()
        return tokens
    }

    /// Greedy word wrap; `\n` is an explicit break. A `nil`/non-finite/zero
    /// `maxWidth` never wraps — Text's single-line default.
    static func wrappedLines(_ string: String, maxWidth: Double?, widthOf measure: (String) -> Double) -> [String] {
        guard let maxWidth, maxWidth.isFinite, maxWidth > 0 else { return string.components(separatedBy: "\n") }
        var lines: [String] = []
        for paragraph in string.split(separator: "\n", omittingEmptySubsequences: false) {
            let tokens = tokenize(paragraph)
            guard !tokens.isEmpty else { lines.append(""); continue }
            var current = ""
            for token in tokens {
                let separator = (token.spaceBefore && !current.isEmpty) ? " " : ""
                let candidate = current + separator + token.text
                if current.isEmpty || measure(candidate) <= maxWidth {
                    current = candidate
                } else {
                    lines.append(current)
                    current = token.text
                }
            }
            lines.append(current)
        }
        return lines
    }

    /// Whether `string` needs `visibleLines` at all: an explicit "\n" always
    /// does (even with room to spare — a hard break stays a hard break); with
    /// none, it's only whether `natural`'s width overflows `maxWidth`. Letting
    /// callers skip straight to `[string]` when this is false keeps the common
    /// short-single-line case down to the one `measureText` call it always
    /// took (Text is measured repeatedly while a stack tree settles, so this
    /// bound directly matters, not just as a nicety).
    static func needsWrapping(_ string: String, natural: Size, maxWidth: Double) -> Bool {
        string.contains("\n") || natural.width > maxWidth
    }

    /// `wrappedLines`, capped to `lineLimit` (`nil` = unlimited) with the last
    /// visible line ellipsised if that cut anything off.
    static func visibleLines(_ string: String, maxWidth: Double?, lineLimit: Int?,
                             widthOf measure: (String) -> Double) -> [String] {
        var lines = wrappedLines(string, maxWidth: maxWidth, widthOf: measure)
        guard let lineLimit, lineLimit > 0, lines.count > lineLimit else { return lines }
        lines = Array(lines.prefix(lineLimit))
        guard var last = lines.popLast() else { return lines }
        if let maxWidth, maxWidth.isFinite, maxWidth > 0 {
            while !last.isEmpty, measure(last + "…") > maxWidth {
                last.removeLast()
            }
        }
        lines.append(last.isEmpty ? "…" : last + "…")
        return lines
    }
}

struct TextLayout: NodeLayout {
    var string: String
    var fontSize: Double
    var font: TextFont
    var lineLimit: Int?

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        let measure = context.environment.measureText
        let natural = measure(string, fontSize, font)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        // No explicit break and it already fits on one line (or nothing
        // constrains it): exactly the pre-wrap behavior, and its one
        // `measureText` call.
        guard Text.needsWrapping(string, natural: natural, maxWidth: width ?? .infinity) else { return natural }
        let lines = Text.visibleLines(string, maxWidth: width, lineLimit: lineLimit) { measure($0, fontSize, font).width }
        // Hugs its widest resulting line, same as an unwrapped Text hugs its
        // one line — `draw` re-deriving lines from that width (`rect.width`)
        // reproduces these exact lines, since none of them is wider than it.
        // A lone, unsplit line is textually `string` itself (no join/space
        // normalization happened), so `natural` already is its width — skips
        // a second `measureText` call for the common single-line-after-all
        // case (e.g. a stack's minimum-size probe considering a short leaf
        // "too wide" against a proposal of zero).
        let contentWidth = (lines.count == 1 && lines[0] == string) ? natural.width
            : lines.map { measure($0, fontSize, font).width }.max() ?? 0
        return Size(width: contentWidth, height: natural.height * Double(lines.count))
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {}
}
