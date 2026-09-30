import Foundation

/// A 2-D affine transform, row-vector convention (`x' = a·x + c·y + tx`) to match
/// CoreGraphics and XRender's `Transform2D`. Render-only — `.transform(_:)`
/// moves the pixels a subtree draws, never its layout.
public struct XTransform: Hashable, Sendable {
    public var a, b, c, d, tx, ty: Double

    public init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, tx: Double = 0, ty: Double = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = XTransform()

    public static func translation(x: Double, y: Double) -> XTransform {
        XTransform(tx: x, ty: y)
    }

    public static func scale(x: Double, y: Double) -> XTransform {
        XTransform(a: x, d: y)
    }

    public static func rotation(_ radians: Double) -> XTransform {
        let s = sin(radians), co = cos(radians)
        return XTransform(a: co, b: s, c: -s, d: co)
    }

    /// `self` followed by `other`.
    public func concatenating(_ other: XTransform) -> XTransform {
        XTransform(
            a: a * other.a + b * other.c,
            b: a * other.b + b * other.d,
            c: c * other.a + d * other.c,
            d: c * other.b + d * other.d,
            tx: tx * other.a + ty * other.c + other.tx,
            ty: tx * other.b + ty * other.d + other.ty
        )
    }

    public var isIdentity: Bool { self == .identity }
}
