import Foundation
import XUI

/// Swallows every draw call; tests assert on the layout result instead.
final class RecordingSurface: XCanvas {
    func fillRect(_ rect: Rect, color: XColorValue) {}
    func fillRoundedRect(_ rect: Rect, cornerRadius: Double, color: XColorValue) {}
    func strokeRoundedRect(_ rect: Rect, cornerRadius: Double, color: XColorValue, lineWidth: Double) {}
    func fillEllipse(in rect: Rect, color: XColorValue) {}
    func fillPath(_ path: Path, in rect: Rect, color: XColorValue) {}
    func strokePath(_ path: Path, in rect: Rect, color: XColorValue, lineWidth: Double) {}
    func drawImage(_ source: ImageSource, in rect: Rect, opacity: Double) {}
    func drawText(_ string: String, in rect: Rect, fontSize: Double, font: TextFont,
                  color: XColorValue, alignment: HorizontalAlignment, outline: TextOutline?) {}
    func measureText(_ string: String, fontSize: Double, font: TextFont) -> Size {
        Size(width: Double(string.count) * fontSize * 0.55, height: fontSize * 1.2)
    }
    func pushClip(_ rect: Rect) {}
    func popClip() {}
    func pushTransform(_ transform: XTransform) {}
    func popTransform() {}
}
