import Foundation
@testable import XUI

/// An `XCanvas` that records calls instead of painting, so layout tests can
/// assert on the rects primitives resolve to.
final class RecordingCanvas: XCanvas {
    struct Fill: Equatable {
        var rect: Rect
        var color: XColorValue
        var cornerRadius: Double
    }
    struct Label: Equatable {
        var string: String
        var rect: Rect
        var fontSize: Double
        var font: TextFont
        var color: XColorValue
        var alignment: HorizontalAlignment
        var outline: TextOutline?
    }
    struct RecordedImage: Equatable {
        var source: ImageSource
        var rect: Rect
        var opacity: Double
    }
    struct RecordedPath: Equatable {
        var path: Path
        var rect: Rect
        var color: XColorValue
        var lineWidth: Double?
    }
    struct Stroke: Equatable {
        var rect: Rect
        var color: XColorValue
        var cornerRadius: Double
        var lineWidth: Double
    }

    private(set) var fills: [Fill] = []
    private(set) var ellipses: [Fill] = []
    private(set) var paths: [RecordedPath] = []
    private(set) var strokes: [Stroke] = []
    private(set) var labels: [Label] = []
    private(set) var images: [RecordedImage] = []
    private var transforms: [XTransform] = []
    var currentTransform: XTransform { transforms.last ?? .identity }

    func pushTransform(_ transform: XTransform) {
        transforms.append(currentTransform.concatenating(transform))
    }
    func popTransform() { _ = transforms.popLast() }

    func fillRect(_ rect: Rect, color: XColorValue) {
        fills.append(Fill(rect: apply(rect), color: color, cornerRadius: 0))
    }

    func fillRoundedRect(_ rect: Rect, cornerRadius: Double, color: XColorValue) {
        fills.append(Fill(rect: apply(rect), color: color, cornerRadius: cornerRadius))
    }

    func strokeRoundedRect(_ rect: Rect, cornerRadius: Double, color: XColorValue, lineWidth: Double) {
        strokes.append(Stroke(rect: apply(rect), color: color, cornerRadius: cornerRadius, lineWidth: lineWidth))
    }

    func fillEllipse(in rect: Rect, color: XColorValue) {
        ellipses.append(Fill(rect: apply(rect), color: color, cornerRadius: 0))
    }

    func fillPath(_ path: Path, in rect: Rect, color: XColorValue) {
        paths.append(RecordedPath(path: path, rect: apply(rect), color: color, lineWidth: nil))
    }

    func strokePath(_ path: Path, in rect: Rect, color: XColorValue, lineWidth: Double) {
        paths.append(RecordedPath(path: path, rect: apply(rect), color: color, lineWidth: lineWidth))
    }

    func drawImage(_ source: ImageSource, in rect: Rect, opacity: Double) {
        images.append(RecordedImage(source: source, rect: apply(rect), opacity: opacity))
    }

    private func apply(_ rect: Rect) -> Rect {
        let t = currentTransform
        guard !t.isIdentity else { return rect }
        let x = t.a * rect.x + t.c * rect.y + t.tx
        let y = t.b * rect.x + t.d * rect.y + t.ty
        return Rect(x: x, y: y, width: rect.width * t.a + rect.height * t.c,
                    height: rect.width * t.b + rect.height * t.d)
    }

    func drawText(
        _ string: String,
        in rect: Rect,
        fontSize: Double,
        font: TextFont,
        color: XColorValue,
        alignment: HorizontalAlignment,
        outline: TextOutline?
    ) {
        labels.append(Label(
            string: string,
            rect: rect,
            fontSize: fontSize,
            font: font,
            color: color,
            alignment: alignment,
            outline: outline
        ))
    }

    func measureText(_ string: String, fontSize: Double, font: TextFont) -> Size {
        let widthFactor = font == .display ? 0.8 : 0.6
        return Size(width: Double(string.count) * fontSize * widthFactor, height: fontSize * 1.3)
    }
}

extension Rect {
    /// Approximate equality for layout assertions (sub-pixel float drift).
    func isApproximately(_ other: Rect, tolerance: Double = 0.01) -> Bool {
        abs(x - other.x) < tolerance
            && abs(y - other.y) < tolerance
            && abs(width - other.width) < tolerance
            && abs(height - other.height) < tolerance
    }
}
