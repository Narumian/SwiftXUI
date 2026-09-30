import Foundation

/// The two-pass walk over a lowered `LayoutNode` tree: measure top-down with a
/// proposal, then place top-down writing absolute frames, then paint.
enum LayoutEngine {
    static func measure(_ node: LayoutNode, _ proposal: ProposedSize, _ context: LayoutContext) -> Size {
        node.measure(proposal, context)
    }

    /// Place `node` at `rect` and recurse. `placeChildren` fills the direct
    /// children's frames; we then walk each subtree.
    @XUIActor
    static func place(_ node: LayoutNode, in rect: Rect, _ context: LayoutContext) async {
        node.frame = rect
        if let make = node.lazyChildren {
            node.children = await make(rect, context)
        }
        node.layout.placeChildren(in: rect, node.children, context)
        for child in node.children {
            await place(child, in: child.frame, context)
        }
    }

    /// Paint the tree and collect anchors / regions. Parent paints before its
    /// children, so children land on top.
    static func render(_ node: LayoutNode, into context: RenderContext) {
        if node.blocksInput { context.inputSuspendedDepth += 1 }
        if let scope = node.focusScopeOverride { context.focusScopeStack.append(scope) }
        defer {
            if node.blocksInput { context.inputSuspendedDepth -= 1 }
            if node.focusScopeOverride != nil { context.focusScopeStack.removeLast() }
        }
        if let id = node.anchor {
            context.setAnchor(id, node.frame)
        }
        if let payload = node.region {
            context.addRegion(node.frame, payload: payload)
        }
        let layerShader = node.shader.flatMap { $0.scope == .layer ? $0 : nil }
        if let shader = node.shader {
            context.addShader(node.frame, shader: shader)
        }
        if let layerShader {
            (context.canvas as? LayerShaderSink)?.beginLayerShader(layerShader, in: node.frame)
        }
        if let control = node.control {
            context.addControl(control, rect: node.frame)
        }
        if let action = node.tapGesture, !node.tapGestureAfterChildren {
            context.addTapGesture(node.frame, id: node.tapGestureID, label: node.tapGestureLabel, action: action)
        }
        let transform = node.transformInFrame?(node.frame) ?? node.transform
        let transformed = transform.map { !$0.isIdentity } ?? false
        if transformed { context.canvas.pushTransform(transform!) }
        if node.clipsToBounds { context.canvas.pushClip(node.frame) }
        node.draw?(node.frame, context)
        for child in node.children {
            render(child, into: context)
        }
        if let action = node.tapGesture, node.tapGestureAfterChildren {
            context.addTapGesture(node.frame, id: node.tapGestureID, label: node.tapGestureLabel, action: action)
        }
        if layerShader != nil {
            (context.canvas as? LayerShaderSink)?.endLayerShader()
        }
        if node.clipsToBounds { context.canvas.popClip() }
        if transformed { context.canvas.popTransform() }
    }
}
