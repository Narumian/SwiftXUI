import Foundation
import XShader

public struct Buffer: X3DProgram, _PrimitiveX3D {
    public typealias Body = Never
    let name: String
    let byteCount: Int

    public init(_ name: String, stride: Int, count: Int) {
        self.name = name
        self.byteCount = stride * count
    }

    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        walk.emit(.resource(.buffer(id: walk.resource(name), byteCount: byteCount)))
    }
}

public struct Texture: X3DProgram, _PrimitiveX3D {
    public typealias Body = Never
    let name: String
    let format: X3DFormat
    let size: X3DSize

    public init(_ name: String, format: X3DFormat = .rgba16Float, size: X3DSize = .target) {
        self.name = name
        self.format = format
        self.size = size
    }

    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        walk.emit(.resource(.texture(id: walk.resource(name), format: format, size: size)))
    }
}

public struct Compute: X3DProgram, _PrimitiveX3D {
    public typealias Body = Never
    let shader: ShaderKey
    let entry: String
    let threads: Int
    let uniforms: [Float]
    var bindings: [(name: String, access: X3DAccess)] = []

    public init(_ shader: ShaderKey, entry: String, threads: Int, uniforms: [Float] = []) {
        self.shader = shader
        self.entry = entry
        self.threads = threads
        self.uniforms = uniforms
    }

    public func bind(_ name: String, access: X3DAccess = .readWrite) -> Self {
        var copy = self
        copy.bindings.append((name, access))
        return copy
    }

    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        let resolved = bindings.map { X3DBinding(resource: walk.resource($0.name), access: $0.access) }
        walk.emit(.compute(X3DCompute(shader: shader, entry: entry, threads: threads,
                                      bindings: resolved, uniforms: uniforms)))
    }
}

public struct Draw: X3DProgram, _PrimitiveX3D {
    public typealias Body = Never
    let shader: ShaderKey
    let vertexEntry: String
    let fragmentEntry: String
    let vertices: Int
    let instances: Int
    let topology: X3DTopology
    let blend: X3DBlend
    let uniforms: [Float]
    var bindings: [(name: String, access: X3DAccess)] = []

    public init(_ shader: ShaderKey, vertex: String = "vs_main", fragment: String = "fs_main",
                vertices: Int, instances: Int = 1, topology: X3DTopology = .triangleList,
                blend: X3DBlend = .alpha, uniforms: [Float] = []) {
        self.shader = shader
        self.vertexEntry = vertex
        self.fragmentEntry = fragment
        self.vertices = vertices
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
        let resolved = bindings.map { X3DBinding(resource: walk.resource($0.name), access: $0.access) }
        walk.emit(.draw(X3DDraw(shader: shader, vertexEntry: vertexEntry, fragmentEntry: fragmentEntry,
                                vertexCount: vertices, instanceCount: instances, topology: topology,
                                blend: blend, bindings: resolved, uniforms: uniforms)))
    }
}

public struct Blit: X3DProgram, _PrimitiveX3D {
    public typealias Body = Never
    let name: String
    let blend: X3DBlend

    public init(_ name: String, blend: X3DBlend = .alpha) {
        self.name = name
        self.blend = blend
    }

    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        walk.emit(.blit(walk.resource(name), blend: blend))
    }
}

public enum PassTarget: Sendable, Equatable, ExpressibleByStringLiteral {
    case output
    case texture(String)

    public init(stringLiteral value: String) { self = .texture(value) }
}

public struct Pass<Content: X3DProgram>: X3DProgram, _PrimitiveX3D {
    public typealias Body = Never
    let target: PassTarget
    let load: X3DLoad
    let content: Content

    public init(into target: PassTarget = .output, load: X3DLoad = .load,
                @XViewBuilder content: () -> Content) {
        self.target = target
        self.load = load
        self.content = content()
    }

    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        let resolved: X3DTarget
        switch target {
        case .output: resolved = .output
        case .texture(let name): resolved = .texture(walk.resource(name))
        }
        walk.emit(.beginPass(target: resolved, load: load))
        await walkX3D(content, id: id.child(type: Content.self), store: store, into: &walk)
        walk.emit(.endPass)
    }
}
