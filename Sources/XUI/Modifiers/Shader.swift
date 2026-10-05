import Foundation
import XShader

/// A render-only shader scope. The subtree keeps its layout slot; the resolved
/// frame and type-erased shader are exported through `RenderResult` for the
/// active renderer to consume.
public struct _ShaderModifier<Content: XView, S: Shader>: XView, _PrimitiveXView {
    public typealias Body = Never

    let content: Content
    let shader: S

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let node = LayoutNode(layout: PassthroughLayout(), children: await lower(content, id: id, store: store))
        node.shader = shader.erased()
        return [node]
    }
}

public extension XView {
    /// Applies a renderer-neutral shader to this view's rendered subtree.
    /// Shader effects do not change measurement or hit regions.
    func shader<S: Shader>(_ shader: S) -> _ShaderModifier<Self, S> {
        _ShaderModifier(content: self, shader: shader)
    }
}

public extension XView {
    func vhsEffect(intensity: Float = 1) -> _ShaderModifier<Self, VHSShader> {
        shader(ShaderLibrary.vhs(intensity: intensity))
    }
}
