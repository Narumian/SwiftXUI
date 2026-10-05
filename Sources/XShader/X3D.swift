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

/// A right-handed perspective camera. `orbit` turns the eye around `target`
/// about `up` at that many radians per second of renderer time.
public struct X3DCamera: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var target: SIMD3<Float>
    public var up: SIMD3<Float>
    public var fieldOfView: Float
    public var near: Float
    public var far: Float
    public var orbit: Float

    public init(position: SIMD3<Float>, target: SIMD3<Float> = .zero, up: SIMD3<Float> = SIMD3(0, 1, 0),
                fieldOfView: Float = .pi / 3, near: Float = 0.05, far: Float = 100, orbit: Float = 0) {
        self.position = position
        self.target = target
        self.up = up
        self.fieldOfView = fieldOfView
        self.near = near
        self.far = far
        self.orbit = orbit
    }

    public func eye(at time: Float) -> SIMD3<Float> {
        guard orbit != 0 else { return position }
        let axis = up / max(length(up), 1e-6)
        let offset = position - target
        let angle = orbit * time
        let parallel = axis * dot(axis, offset)
        let radial = offset - parallel
        let rotated = radial * cos(angle) + cross(axis, radial) * sin(angle)
        return target + parallel + rotated
    }

    /// Column-major view-projection with WebGPU's 0…1 clip depth.
    public func viewProjection(aspect: Float, time: Float) -> [Float] {
        let eye = eye(at: time)
        let z = normalized(eye - target)
        let x = normalized(cross(up, z))
        let y = cross(z, x)
        let view: [Float] = [
            x.x, y.x, z.x, 0,
            x.y, y.y, z.y, 0,
            x.z, y.z, z.z, 0,
            -dot(x, eye), -dot(y, eye), -dot(z, eye), 1,
        ]
        let f = 1 / tan(fieldOfView / 2)
        let projection: [Float] = [
            f / max(aspect, 1e-6), 0, 0, 0,
            0, f, 0, 0,
            0, 0, far / (near - far), -1,
            0, 0, near * far / (near - far), 0,
        ]
        var result = [Float](repeating: 0, count: 16)
        for column in 0..<4 {
            for row in 0..<4 {
                var sum: Float = 0
                for k in 0..<4 { sum += projection[k * 4 + row] * view[column * 4 + k] }
                result[column * 4 + row] = sum
            }
        }
        return result
    }
}

private func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }
private func length(_ a: SIMD3<Float>) -> Float { dot(a, a).squareRoot() }
private func normalized(_ a: SIMD3<Float>) -> SIMD3<Float> { a / max(length(a), 1e-6) }
private func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
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
    public var camera: X3DCamera?

    public init(shader: ShaderKey, vertexEntry: String, fragmentEntry: String,
                vertexCount: Int, instanceCount: Int = 1,
                topology: X3DTopology = .triangleList, blend: X3DBlend = .alpha,
                bindings: [X3DBinding] = [], uniforms: [Float] = [], camera: X3DCamera? = nil) {
        self.shader = shader
        self.vertexEntry = vertexEntry
        self.fragmentEntry = fragmentEntry
        self.vertexCount = vertexCount
        self.instanceCount = instanceCount
        self.topology = topology
        self.blend = blend
        self.bindings = bindings
        self.uniforms = uniforms
        self.camera = camera
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
    case beginPass(target: X3DTarget, load: X3DLoad, depth: Bool)
    case draw(X3DDraw)
    case blit(X3DResourceID, blend: X3DBlend)
    case endPass
}
