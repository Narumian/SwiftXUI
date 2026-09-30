import XShader

/// A renderer-neutral shader attached to a resolved scene region. The scene
/// carries this descriptor; each backend chooses how to compile and execute
/// the shader identified by `shader.key`.
public struct ShaderRegion: Sendable, Equatable {
    public var rect: RenderRect
    public var shader: AnyShader

    public init(rect: RenderRect, shader: AnyShader) {
        self.rect = rect
        self.shader = shader
    }
}
