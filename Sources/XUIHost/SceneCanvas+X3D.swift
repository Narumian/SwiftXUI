import XRender
import XShader
import XUI

extension SceneCanvas: XUI.X3DSink {
    public func beginX3D(in rect: XUI.Rect) {
        builder.beginX3D(in: rect.render)
    }

    public func emitX3D(_ op: X3DOp) {
        builder.emitX3D(op)
    }

    public func beginX3DView(in rect: XUI.Rect) {
        builder.beginX3DView(in: rect.render)
    }

    public func endX3DView() {
        builder.endX3DView()
    }

    public func endX3D() {
        builder.endX3D()
    }
}
