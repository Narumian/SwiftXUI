import Foundation
import XRender
import XShader

/// Hosts an `X3DProgram` in a view's layout slot. It takes the size its
/// parent offers; the program renders into that rect at its place in paint
/// order. Without an `X3DSink` canvas only the embedded views are drawn.
public struct X3DView<Content: X3DProgram>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content

    public init(@XViewBuilder content: () -> Content) {
        self.content = content()
    }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let scope = id.child(type: X3DView.self)
        let probe = X3DCostProbe.shared
        let walkStarted = probe.begin(.walk)
        var walk = X3DWalk(scope: scope.hashValue)
        await walkX3D(content, id: scope, store: store, into: &walk)
        walk.finish()
        probe.end(.walk, started: walkStarted)
        let steps = walk.steps
        let embedded = steps.compactMap { step -> LayoutNode? in
            if case .view(let node) = step { return node }
            return nil
        }
        let planes = steps.compactMap { step -> LayoutNode? in
            if case .plane(let node, _, _, _) = step { return node }
            return nil
        }
        let node = LayoutNode(layout: X3DViewLayout())
        node.lazyChildren = { rect, context in
            for child in embedded {
                let size = child.measure(ProposedSize(rect.size), context)
                await LayoutEngine.place(child, in: Alignment.center.position(size, in: rect), context)
            }
            for plane in planes {
                let size = plane.measure(ProposedSize(width: nil, height: nil), context)
                await LayoutEngine.place(plane, in: Rect(x: 0, y: 0, width: size.width, height: size.height), context)
            }
            return []
        }
        node.draw = { rect, context in
            guard let sink = context.canvas as? X3DSink else {
                for child in embedded { LayoutEngine.render(child, into: context) }
                return
            }
            sink.beginX3D(in: rect)
            for step in steps {
                switch step {
                case .op(let op):
                    sink.emitX3D(op)
                case .view(let child):
                    sink.beginX3DView(in: child.frame)
                    LayoutEngine.render(child, into: context)
                    sink.endX3DView()
                case .plane(let child, let camera, let model, let acceptsInput):
                    sink.beginX3DPlane(size: child.frame.size)
                    if acceptsInput {
                        let marker = context.beginPlaneInputCapture()
                        LayoutEngine.render(child, into: context)
                        context.endPlaneInputCapture(
                            marker,
                            hostRect: rect,
                            planeSize: child.frame.size,
                            camera: camera,
                            model: model
                        )
                    } else {
                        LayoutEngine.render(child, into: context)
                    }
                    sink.endX3DPlane(camera: camera, model: model)
                }
            }
            sink.endX3D()
        }
        return [node]
    }
}

struct X3DViewLayout: NodeLayout {
    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        proposal.resolved()
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {}
}
