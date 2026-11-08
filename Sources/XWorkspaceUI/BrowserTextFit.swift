import Foundation
import XUI

/// Fits file names into cells, remembering the answers.
///
/// Cutting a name to a width takes a measurement of the whole string and then a
/// binary search over its prefixes: about five text measurements per cell, every
/// frame, for text that does not change. The answers are remembered by (text,
/// size, width), so a steady frame costs none. Glyph metrics can change under
/// the cache when a font finishes loading, so each render pass re-measures one
/// reference string and drops everything if it moved.
final class BrowserTextFit: @unchecked Sendable {
    static let shared = BrowserTextFit()

    private struct Key: Hashable {
        var text: String
        var size: Int
        var width: Int
        var middle: Bool
    }

    private let lock = NSLock()
    private var fits: [Key: String] = [:]
    private var widths: [Key: Double] = [:]
    private weak var epochContext: RenderContext?
    private var probe = -1.0
    private static let capacity = 8192

    /// One line that fits `maxWidth`. A cut file name keeps its extension
    /// ("alpha mask 1….jpg"), because the end of a name is what tells two files apart.
    func fit(_ string: String, size: Double, maxWidth: Double, middle: Bool, context: RenderContext) -> String {
        let key = Key(text: string, size: Int(size * 10), width: Int(maxWidth * 4), middle: middle)
        let measure = context.environment.measureText
        validate(context, measure)
        if let hit = lock.withLock({ fits[key] }) { return hit }
        let result = Self.compute(string, size: size, maxWidth: maxWidth, middle: middle, measure: measure)
        lock.withLock {
            if fits.count >= Self.capacity { fits.removeAll(keepingCapacity: true) }
            fits[key] = result
        }
        return result
    }

    /// The width of a short label, measured once.
    func width(_ string: String, size: Double, context: RenderContext) -> Double {
        let key = Key(text: string, size: Int(size * 10), width: 0, middle: false)
        let measure = context.environment.measureText
        validate(context, measure)
        if let hit = lock.withLock({ widths[key] }) { return hit }
        let value = measure(string, size, .ui).width
        lock.withLock {
            if widths.count >= Self.capacity { widths.removeAll(keepingCapacity: true) }
            widths[key] = value
        }
        return value
    }

    /// Once per render pass: have the glyph metrics moved?
    private func validate(_ context: RenderContext, _ measure: TextMeasurer) {
        let current = lock.withLock { epochContext === context }
        if current { return }
        let measured = measure("Mg…ij", 13, .ui).width
        lock.withLock {
            if measured != probe { fits.removeAll(keepingCapacity: true); widths.removeAll(keepingCapacity: true) }
            probe = measured
            epochContext = context
        }
    }

    static func compute(_ string: String, size: Double, maxWidth: Double, middle: Bool, measure: TextMeasurer) -> String {
        if measure(string, size, .ui).width <= maxWidth { return string }
        let characters = Array(string)
        var tail: [Character] = []
        if middle, let dot = characters.lastIndex(of: "."), dot > 0, characters.count - dot <= 6 {
            // Keep the number before the extension too: "…12.jpg" tells files apart, "….jpg" does not.
            var start = dot
            while start > 0, characters[start - 1].isNumber, dot - start < 4 { start -= 1 }
            tail = Array(characters[start...])
        }
        // The longest head such that head + "…" + tail fits.
        var low = 0, high = characters.count - tail.count
        while low < high {
            let mid = (low + high + 1) / 2
            if measure(String(characters[..<mid]) + "…" + String(tail), size, .ui).width <= maxWidth { low = mid } else { high = mid - 1 }
        }
        if low == 0 && !tail.isEmpty {
            // Not even "…ext" with a letter fits: fall back to cutting the end.
            return compute(string, size: size, maxWidth: maxWidth, middle: false, measure: measure)
        }
        return low == 0 ? "…" : String(characters[..<low]) + "…" + String(tail)
    }
}
