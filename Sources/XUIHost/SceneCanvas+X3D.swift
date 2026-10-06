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

    public func beginX3DPlane(size: XUI.Size) {
        builder.beginX3DPlane(size: RenderSize(width: Float(size.width), height: Float(size.height)))
    }

    public func endX3DPlane(camera: X3DCamera, model: X3DTransform) {
        builder.endX3DPlane(camera: camera, model: model)
    }

    public func endX3D() {
        builder.endX3D()
    }
}

extension SceneCanvas: XUI.X3DDiagnosticSource {
    public var x3dGraphs: [X3DGraph] {
        scene.commands.compactMap { command in
            if case .x3d(let x3d) = command { return x3d.graph }
            return nil
        }
    }
}
