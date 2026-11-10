import Foundation

/// The drawing surface XUI renders into. The core ships no implementation;
/// `XUIHost` conforms `SceneBuilder` to this, and a test double
/// conforms for unit tests.
///
/// A reference type: the layout walk hands the same instance to every leaf's
/// draw callback and expects painting to accumulate.
public protocol XCanvas: AnyObject {
    func fillRect(_ rect: Rect, color: XColorValue)
    func fillRoundedRect(_ rect: Rect, cornerRadius: Double, color: XColorValue)
    func strokeRoundedRect(_ rect: Rect, cornerRadius: Double, color: XColorValue, lineWidth: Double)
    func fillEllipse(in rect: Rect, color: XColorValue)
    func fillPath(_ path: Path, in rect: Rect, color: XColorValue)
    func strokePath(_ path: Path, in rect: Rect, color: XColorValue, lineWidth: Double)
    func hairlinePath(_ path: Path, in rect: Rect, color: XColorValue)
    func drawImage(_ source: ImageSource, in rect: Rect, opacity: Double)
    func drawText(
        _ string: String,
        in rect: Rect,
        fontSize: Double,
        font: TextFont,
        color: XColorValue,
        alignment: HorizontalAlignment,
        outline: TextOutline?
    )
    /// Advance width of `string` at `fontSize`, for `Text` sizing.
    func measureText(_ string: String, fontSize: Double, font: TextFont) -> Size
    func pushClip(_ rect: Rect)
    func popClip()
    /// Render-only affine transform, scoped push/pop. `.transform(_:)` uses it.
    func pushTransform(_ transform: XTransform)
    func popTransform()
}

/// Optional canvas capability for 3D laser geometry. Vertices remain in the
/// source `position4 + rgba4` Float32 layout; the renderer applies `matrix` in
/// its vertex shader and draws only the supplied contiguous ranges.
public protocol LaserPreviewSink: AnyObject {
    func drawLaserPreview(vertices: [Float], modes: [UInt16], shapes: [Range<Int>],
                          matrix: [Float], in rect: Rect)
}

public extension XCanvas {
    func fillRoundedRect(_ rect: Rect, cornerRadius: Double, color: XColorValue) {
        fillRect(rect, color: color)
    }
    func strokeRoundedRect(_ rect: Rect, cornerRadius: Double, color: XColorValue, lineWidth: Double) {}
    func fillEllipse(in rect: Rect, color: XColorValue) {
        fillRect(rect, color: color)
    }
    func fillPath(_ path: Path, in rect: Rect, color: XColorValue) {}
    func strokePath(_ path: Path, in rect: Rect, color: XColorValue, lineWidth: Double) {}
    func hairlinePath(_ path: Path, in rect: Rect, color: XColorValue) {
        strokePath(path, in: rect, color: color, lineWidth: 1)
    }
    func drawImage(_ source: ImageSource, in rect: Rect, opacity: Double) {}
    func measureText(_ string: String, fontSize: Double, font: TextFont) -> Size {
        Size(width: Double(string.count) * fontSize * 0.6, height: fontSize * 1.3)
    }
    func pushClip(_ rect: Rect) {}
    func popClip() {}
    func pushTransform(_ transform: XTransform) {}
    func popTransform() {}
}
