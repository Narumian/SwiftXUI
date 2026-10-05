import Foundation
import XShader

/// Uploads interleaved `position.xyz, normal.xyz` mesh floats and draws them.
/// Prefer this over hand-counting vertices from `X3DMesh` contents.
public struct MeshDraw: X3DProgram, _PrimitiveX3D {
    public typealias Body = Never
    let bufferName: String
    let mesh: [Float]
    let shader: ShaderKey
    let vertexEntry: String
    let fragmentEntry: String
    let instances: Int
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

    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        walk.emit(.resource(.buffer(
            id: walk.resource(bufferName),
            byteCount: mesh.count * MemoryLayout<Float>.stride,
            contents: mesh
        )))
        var resolved = [X3DBinding(resource: walk.resource(bufferName), access: .read)]
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
