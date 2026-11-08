import Foundation

/// Converts between character offsets and horizontal positions for one line of
/// text, using the canvas's own text measurer so the caret lands exactly
/// between glyphs as they are drawn.
struct TextMetrics {
    var text: TextEditing
    var fontSize: Double
    var font: TextFont
    var measure: TextMeasurer

    /// Distance from the start of the line to the left edge of character `offset`.
    func x(of offset: Int) -> Double {
        guard offset > 0 else { return 0 }
        return measure(text.prefix(offset), fontSize, font).width
    }

    var totalWidth: Double {
        text.isEmpty ? 0 : measure(text.text, fontSize, font).width
    }

    var lineHeight: Double { measure("Ag", fontSize, font).height }

    /// The caret offset nearest to horizontal position `x` (relative to the line start).
    /// Binary search over prefix widths: log₂(n) measurements, not n.
    func offset(at x: Double) -> Int {
        let count = text.count
        guard count > 0, x > 0 else { return 0 }
        if x >= totalWidth { return count }
        var low = 0, high = count   // x(low) <= x < x(high)
        while high - low > 1 {
            let mid = (low + high) / 2
            if self.x(of: mid) <= x { low = mid } else { high = mid }
        }
        // Snap to whichever edge of the character is closer.
        let left = self.x(of: low), right = self.x(of: high)
        return (x - left) < (right - x) ? low : high
    }

    /// New horizontal scroll that keeps the caret inside the visible width with a small lead,
    /// never scrolling past the text and never leaving blank space after deleting.
    static func scroll(
        current: Double, caretX: Double, textWidth: Double, visibleWidth: Double, caretWidth: Double
    ) -> Double {
        guard visibleWidth > 0 else { return 0 }
        let lead = min(visibleWidth * 0.2, 24)
        var scroll = current
        if caretX - scroll > visibleWidth - caretWidth - lead { scroll = caretX - visibleWidth + caretWidth + lead }
        if caretX - scroll < lead { scroll = caretX - lead }
        let maxScroll = max(0, textWidth + caretWidth - visibleWidth)
        return min(max(0, scroll), maxScroll)
    }
}
