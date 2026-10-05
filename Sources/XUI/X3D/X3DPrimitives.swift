import Foundation
import XShader

public struct Buffer: X3DProgram, _PrimitiveX3D {
    public typealias Body = Never
    let name: String
    let byteCount: Int
    let contents: [Float]?

    public init(_ name: String, stride: Int, count: Int) {
        self.name = name
        self.byteCount = stride * count
        self.contents = nil
    }

    public init(_ name: String, contents: [Float]) {
        self.name = name
        self.byteCount = contents.count * MemoryLayout<Float>.stride
        self.contents = contents
    }

    /// One column-major `mat4x4<f32>` per instance, for `instance_index` lookups.
    public init(_ name: String, transforms: [X3DTransform]) {
        self.init(name, contents: transforms.flatMap(\.matrix))
    }

    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        walk.emit(.resource(.buffer(id: walk.resource(name), byteCount: byteCount, contents: contents)))
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
                                blend: blend, bindings: resolved, uniforms: uniforms, camera: walk.camera, model: walk.model)))
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
    let depth: Bool
    let content: Content

    public init(into target: PassTarget = .output, load: X3DLoad = .load, depth: Bool = false,
                @XViewBuilder content: () -> Content) {
        self.target = target
        self.load = load
        self.depth = depth
        self.content = content()
    }

    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        let resolved: X3DTarget
        switch target {
        case .output: resolved = .output
        case .texture(let name): resolved = .texture(walk.resource(name))
        }
        walk.emit(.beginPass(target: resolved, load: load, depth: depth))
        await walkX3D(content, id: id.child(type: Content.self), store: store, into: &walk)
        walk.emit(.endPass)
    }
}

/// Draws inside see this camera's view-projection as `x3d.viewProjection`.
public struct Camera<Content: X3DProgram>: X3DProgram, _PrimitiveX3D {
    public typealias Body = Never
    let camera: X3DCamera
    let content: Content

    public init(position: SIMD3<Float>, target: SIMD3<Float> = .zero, fieldOfView: Float = .pi / 3,
                near: Float = 0.05, far: Float = 100, orbit: Float = 0,
                @XViewBuilder content: () -> Content) {
        self.camera = X3DCamera(position: position, target: target, fieldOfView: fieldOfView,
                                near: near, far: far, orbit: orbit)
        self.content = content()
    }

    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        let outer = walk.camera
        walk.camera = camera
        await walkX3D(content, id: id.child(type: Content.self), store: store, into: &walk)
        walk.camera = outer
    }
}

public struct Transform3D<Content: X3DProgram>: X3DProgram, _PrimitiveX3D {
    public typealias Body = Never
    let transform: X3DTransform
    let content: Content

    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        let outer = walk.model
        walk.model = outer * transform
        await walkX3D(content, id: id.child(type: Content.self), store: store, into: &walk)
        walk.model = outer
    }
}

public extension X3DProgram {
    /// Applies `transform` to the draws inside, after any enclosing transform.
    func transform3D(_ transform: X3DTransform) -> Transform3D<Self> {
        Transform3D(transform: transform, content: self)
    }
}
