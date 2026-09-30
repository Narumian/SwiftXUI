import Foundation

/// 2D affine transform. Element layout and composition match `CGAffineTransform`
/// (row-vector convention: `x' = a·x + c·y + tx`), so editor code and this
/// renderer agree without conversion.
public struct Transform2D: Sendable, Equatable {
    public var a: Float
    public var b: Float
    public var c: Float
    public var d: Float
    public var tx: Float
    public var ty: Float

    public init(a: Float = 1, b: Float = 0, c: Float = 0, d: Float = 1, tx: Float = 0, ty: Float = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = Transform2D()

    public static func translation(x: Float, y: Float) -> Transform2D {
        Transform2D(tx: x, ty: y)
    }

    public static func scale(x: Float, y: Float) -> Transform2D {
        Transform2D(a: x, d: y)
    }

    public static func rotation(_ radians: Float) -> Transform2D {
        let s = sin(radians), co = cos(radians)
        return Transform2D(a: co, b: s, c: -s, d: co)
    }

    public func apply(_ point: RenderPoint) -> RenderPoint {
        RenderPoint(x: a * point.x + c * point.y + tx, y: b * point.x + d * point.y + ty)
    }

    /// `self` followed by `other` (same as `CGAffineTransform.concatenating`).
    public func concatenating(_ other: Transform2D) -> Transform2D {
        Transform2D(
            a: a * other.a + b * other.c,
            b: a * other.b + b * other.d,
            c: c * other.a + d * other.c,
            d: c * other.b + d * other.d,
            tx: tx * other.a + ty * other.c + other.tx,
            ty: tx * other.b + ty * other.d + other.ty
        )
    }

    public func translatedBy(x: Float, y: Float) -> Transform2D {
        Transform2D.translation(x: x, y: y).concatenating(self)
    }

    public func rotatedBy(_ radians: Float) -> Transform2D {
        Transform2D.rotation(radians).concatenating(self)
    }

    public func scaledBy(x: Float, y: Float) -> Transform2D {
        Transform2D.scale(x: x, y: y).concatenating(self)
    }

    /// Uniform-ish scale magnitude, for picking a tessellation density.
    public var approximateScale: Float {
        (abs(a) + abs(d)) * 0.5
    }
}
