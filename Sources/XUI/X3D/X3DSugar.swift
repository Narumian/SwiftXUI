import Foundation
import XShader

/// Uploads interleaved `position.xyz, normal.xyz` mesh floats and draws them.
/// Prefer this over hand-counting vertices from `X3DMesh` contents.
///
/// For many copies of the same mesh, use ``instanced(transforms:name:)`` — that
/// is the real authoring win over composing `Buffer` + `Draw` by hand.
/// `Instanced` alone is for vertex-index / non-mesh geometry.
public struct MeshDraw: X3DProgram, _PrimitiveX3D {
    public typealias Body = Never
    let bufferName: String
    let mesh: [Float]
    var instanceName: String?
    var transforms: [X3DTransform]?
    let shader: ShaderKey
    let vertexEntry: String
    let fragmentEntry: String
    var instances: Int
    let topology: X3DTopology
    let blend: X3DBlend
    let uniforms: [Float]
    var bindings: [(name: String, access: X3DAccess)] = []

    public init(
        _ shader: ShaderKey,
        mesh: [Float],
        name: String = "mesh",
        vertex: String = "vs_main",
        fragment: String = "fs_main",
        instances: Int = 1,
        topology: X3DTopology = .triangleList,
        blend: X3DBlend = .alpha,
        uniforms: [Float] = []
    ) {
        self.shader = shader
        self.mesh = mesh
        self.bufferName = name
        self.instanceName = nil
        self.transforms = nil
        self.vertexEntry = vertex
        self.fragmentEntry = fragment
        self.instances = instances
        self.topology = topology
        self.blend = blend
        self.uniforms = uniforms
    }

    public func bind(_ name: String, access: X3DAccess = .read) -> Self {
        var copy = self
        copy.bindings.append((name, access))
        return copy
    }

    /// Declares a per-instance transform buffer and draws `mesh × transforms`.
    public func instanced(transforms: [X3DTransform], name: String = "instances") -> Self {
        var copy = self
        copy.transforms = transforms
        copy.instanceName = name
        copy.instances = max(transforms.count, 1)
        return copy
    }

    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        walk.emit(.resource(.buffer(
            id: walk.resource(bufferName),
            byteCount: mesh.count * MemoryLayout<Float>.stride,
            contents: mesh
        )))
        var resolved = [X3DBinding(resource: walk.resource(bufferName), access: .read)]
        if let transforms, let instanceName {
            let contents = transforms.flatMap(\.matrix)
            walk.emit(.resource(.buffer(
                id: walk.resource(instanceName),
                byteCount: contents.count * MemoryLayout<Float>.stride,
                contents: contents
            )))
            resolved.append(X3DBinding(resource: walk.resource(instanceName), access: .read))
        }
        resolved += bindings.map { X3DBinding(resource: walk.resource($0.name), access: $0.access) }
        walk.emit(.draw(X3DDraw(
            shader: shader,
            vertexEntry: vertexEntry,
            fragmentEntry: fragmentEntry,
            vertexCount: mesh.count / X3DMesh.floatsPerVertex,
            instanceCount: instances,
            topology: topology,
            blend: blend,
            bindings: resolved,
            uniforms: uniforms,
            camera: walk.camera,
            model: walk.model
        )))
    }
}

/// A three-vertex fullscreen triangle for vertex-index shaders (no mesh buffer).
public struct Fullscreen: X3DProgram, _PrimitiveX3D {
    public typealias Body = Never
    let shader: ShaderKey
    let vertexEntry: String
    let fragmentEntry: String
    let blend: X3DBlend
    let uniforms: [Float]
    var bindings: [(name: String, access: X3DAccess)] = []

    public init(
        _ shader: ShaderKey,
        vertex: String = "vs_main",
        fragment: String = "fs_main",
        blend: X3DBlend = .alpha,
        uniforms: [Float] = []
    ) {
        self.shader = shader
        self.vertexEntry = vertex
        self.fragmentEntry = fragment
        self.blend = blend
        self.uniforms = uniforms
    }

    public func bind(_ name: String, access: X3DAccess = .read) -> Self {
        var copy = self
        copy.bindings.append((name, access))
        return copy
    }

    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        let resolved = bindings.map { X3DBinding(resource: walk.resource($0.name), access: $0.access) }
        walk.emit(.draw(X3DDraw(
            shader: shader,
            vertexEntry: vertexEntry,
            fragmentEntry: fragmentEntry,
            vertexCount: 3,
            instanceCount: 1,
            topology: .triangleList,
            blend: blend,
            bindings: resolved,
            uniforms: uniforms,
            camera: walk.camera,
            model: walk.model
        )))
    }
}

/// Declares a per-instance transform buffer and draws `vertices × transforms.count`.
/// Prefer ``MeshDraw/instanced(transforms:name:)`` when the geometry is an
/// `X3DMesh` float buffer — this type is for vertex-index / particle sprites.
public struct Instanced: X3DProgram, _PrimitiveX3D {
    public typealias Body = Never
    let bufferName: String
    let transforms: [X3DTransform]
    let shader: ShaderKey
    let vertexEntry: String
    let fragmentEntry: String
    let vertices: Int
    let topology: X3DTopology
    let blend: X3DBlend
    let uniforms: [Float]
    var bindings: [(name: String, access: X3DAccess)] = []

    public init(
        _ shader: ShaderKey,
        transforms: [X3DTransform],
        vertices: Int,
        name: String = "instances",
        vertex: String = "vs_main",
        fragment: String = "fs_main",
        topology: X3DTopology = .triangleList,
        blend: X3DBlend = .alpha,
        uniforms: [Float] = []
    ) {
        self.shader = shader
        self.transforms = transforms
        self.vertices = vertices
        self.bufferName = name
        self.vertexEntry = vertex
        self.fragmentEntry = fragment
        self.topology = topology
        self.blend = blend
        self.uniforms = uniforms
    }

    public func bind(_ name: String, access: X3DAccess = .read) -> Self {
        var copy = self
        copy.bindings.append((name, access))
        return copy
    }

    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        let contents = transforms.flatMap(\.matrix)
        walk.emit(.resource(.buffer(
            id: walk.resource(bufferName),
            byteCount: contents.count * MemoryLayout<Float>.stride,
            contents: contents
        )))
        var resolved = [X3DBinding(resource: walk.resource(bufferName), access: .read)]
        resolved += bindings.map { X3DBinding(resource: walk.resource($0.name), access: $0.access) }
        walk.emit(.draw(X3DDraw(
            shader: shader,
            vertexEntry: vertexEntry,
            fragmentEntry: fragmentEntry,
            vertexCount: vertices,
            instanceCount: transforms.count,
            topology: topology,
            blend: blend,
            bindings: resolved,
            uniforms: uniforms,
            camera: walk.camera,
            model: walk.model
        )))
    }
}

/// Feedback trail: offscreen texture with fade load, draw into it, blit to output.
/// This is the particle/trail pattern from the X3D recipes, as one program node.
public struct FeedbackTrail<Content: X3DProgram>: X3DProgram, _PrimitiveX3D {
    public typealias Body = Never
    let textureName: String
    let format: X3DFormat
    let size: X3DSize
    let fade: Float
    let blitBlend: X3DBlend
    let content: Content

    public init(
        _ textureName: String = "trail",
        format: X3DFormat = .rgba16Float,
        size: X3DSize = .target,
        fade: Float = 0.1,
        blitBlend: X3DBlend = .alpha,
        @XViewBuilder content: () -> Content
    ) {
        self.textureName = textureName
        self.format = format
        self.size = size
        self.fade = fade
        self.blitBlend = blitBlend
        self.content = content()
    }

    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        walk.emit(.resource(.texture(id: walk.resource(textureName), format: format, size: size)))
        walk.emit(.beginPass(target: .texture(walk.resource(textureName)), load: .fade(fade), depth: false))
        await walkX3D(content, id: id.child(type: Content.self), store: store, into: &walk)
        walk.emit(.endPass)
        walk.emit(.blit(walk.resource(textureName), blend: blitBlend))
    }
}
