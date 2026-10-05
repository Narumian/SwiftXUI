import Foundation
import XShader

/// Optional canvas capability that receives an `X3DView`'s lowered program.
/// Embedded views are bracketed by `beginX3DView`/`endX3DView`; whatever the
/// canvas records between them belongs to that view.
public protocol X3DSink: AnyObject {
    func beginX3D(in rect: Rect)
    func emitX3D(_ op: X3DOp)
    func beginX3DView(in rect: Rect)
    func endX3DView()
    /// A view placed inside a `Camera`: its commands become a plane of
    /// `size` points, drawn in 3D with `camera` and `model`.
    func beginX3DPlane(size: Size)
    func endX3DPlane(camera: X3DCamera, model: X3DTransform)
    func endX3D()
}
