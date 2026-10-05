import Foundation

/// A GPU resource owned by the renderer across frames. `scope` is the
/// structural identity of the program that declared it, so two instances of
/// the same program never share state.
public struct X3DResourceID: Hashable, Sendable {
    public var scope: Int
    public var name: String

    public init(scope: Int, name: String) {
        self.scope = scope
        self.name = name
    }
}

public enum X3DFormat: String, Sendable, Equatable {
    case rgba8Unorm
    case rgba16Float
    case r32Float
}

public enum X3DSize: Sendable, Equatable {
    case target
    /// The target size times `factor`, at least one pixel.
    case scaled(Float)
    case fixed(width: Int, height: Int)
}

public enum X3DResource: Sendable, Equatable {
    case buffer(id: X3DResourceID, byteCount: Int)
    case texture(id: X3DResourceID, format: X3DFormat, size: X3DSize)

    public var id: X3DResourceID {
        switch self {
        case .buffer(let id, _), .texture(let id, _, _): return id
        }
    }
}

public enum X3DAccess: Sendable, Equatable {
    case read
    case readWrite
}

public struct X3DBinding: Sendable, Equatable {
    public var resource: X3DResourceID
    public var access: X3DAccess

    public init(resource: X3DResourceID, access: X3DAccess) {
        self.resource = resource
        self.access = access
    }
}

/// One dispatch. The shader's entry point declares `@workgroup_size(64)`;
/// the renderer dispatches `ceil(threads / 64)` workgroups.
public struct X3DCompute: Sendable, Equatable {
    public var shader: ShaderKey
    public var entry: String
    public var threads: Int
    public var bindings: [X3DBinding]
    public var uniforms: [Float]

    public init(shader: ShaderKey, entry: String, threads: Int,
                bindings: [X3DBinding] = [], uniforms: [Float] = []) {
        self.shader = shader
        self.entry = entry
        self.threads = threads
        self.bindings = bindings
        self.uniforms = uniforms
    }
}

public enum X3DTopology: Sendable, Equatable {
    case triangleList
    case triangleStrip
    case lineList
    case pointList
}

public enum X3DBlend: Sendable, Equatable {
    case opaque
    case alpha
    case additive
}

public struct X3DDraw: Sendable, Equatable {
    public var shader: ShaderKey
    public var vertexEntry: String
    public var fragmentEntry: String
    public var vertexCount: Int
    public var instanceCount: Int
    public var topology: X3DTopology
    public var blend: X3DBlend
    public var bindings: [X3DBinding]
    public var uniforms: [Float]

    public init(shader: ShaderKey, vertexEntry: String, fragmentEntry: String,
                vertexCount: Int, instanceCount: Int = 1,
                topology: X3DTopology = .triangleList, blend: X3DBlend = .alpha,
                bindings: [X3DBinding] = [], uniforms: [Float] = []) {
        self.shader = shader
        self.vertexEntry = vertexEntry
        self.fragmentEntry = fragmentEntry
        self.vertexCount = vertexCount
        self.instanceCount = instanceCount
        self.topology = topology
        self.blend = blend
        self.bindings = bindings
        self.uniforms = uniforms
    }
}

/// `output` is the hosting view's own rect.
public enum X3DTarget: Sendable, Equatable {
    case output
    case texture(X3DResourceID)
}

public enum X3DLoad: Sendable, Equatable {
    case load
    case clear(SIMD4<Float>)
    /// Multiply the previous contents toward transparent by `amount` (0…1).
    case fade(Float)
}

/// The renderer-neutral stream a program tree lowers to. Embedded views
/// travel separately because their content is backend-specific.
public enum X3DOp: Sendable, Equatable {
    case resource(X3DResource)
    case compute(X3DCompute)
    case beginPass(target: X3DTarget, load: X3DLoad)
    case draw(X3DDraw)
    case blit(X3DResourceID, blend: X3DBlend)
    case endPass
}
