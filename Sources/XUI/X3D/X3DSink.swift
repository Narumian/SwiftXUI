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
    func endX3D()
}
