import Foundation
import simd

/// A shape's identity: a stable integer chosen by whoever produces the shape.
/// It is not the shape's index. An index is a position in one frame and changes
/// when shapes are added or reordered; an identity names the same shape across
/// frames, so effects, materials, morphs and routing can address it.
public struct LaserShapeID: Hashable, Sendable, ExpressibleByIntegerLiteral {
    public var rawValue: UInt32
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
    public init(integerLiteral value: UInt32) { rawValue = value }
}

/// A vertex before projection onto the scanner. The position is homogeneous
/// (x, y, z, w) so 2D and 3D shapes share one type: a 2D shape uses z = 0 and
/// w = 1, and the projection stage divides by w. Geometry is `Double` because
/// transforms are stacked as matrices; the projection stage narrows to the
/// `Float` of `LaserPoint`. Nothing here is limited to the scanner's -1...1
/// range; clipping happens at projection.
public struct LaserVertex: Equatable, Sendable {
    /// The scanner's treatment of this vertex; the same type a `LaserPoint` carries.
    public typealias Mode = LaserPointMode

    public var position: SIMD4<Double>
    /// Colour with alpha. Alpha is multiplied into the colour at projection.
    public var rgba: SIMD4<Double>
    public var mode: Mode

    public init(position: SIMD4<Double>, rgba: SIMD4<Double>, mode: Mode = .normal) {
        self.position = position; self.rgba = rgba; self.mode = mode
    }
    public init(x: Double, y: Double, z: Double = 0, w: Double = 1, rgba: SIMD4<Double> = .one, mode: Mode = .normal) {
        self.init(position: SIMD4<Double>(x, y, z, w), rgba: rgba, mode: mode)
    }

    public var xy: SIMD2<Double> { SIMD2<Double>(position.x, position.y) }
    public var isBlanked: Bool { mode == .blank }

    /// The same place, dark.
    public func blanked() -> LaserVertex { var v = self; v.rgba = .zero; v.mode = .blank; return v }
    /// The same place and colour, held still.
    public func dwelling() -> LaserVertex { var v = self; v.mode = .dwell; return v }
    public func transformed(by matrix: simd_double4x4) -> LaserVertex { var v = self; v.position = matrix * position; return v }
    public func scaledAlpha(_ alpha: Double) -> LaserVertex { var v = self; v.rgba.w *= alpha; return v }
}

/// One whole shape in the front half of the pipeline (3D, before projection): a path
/// of vertices that the beam follows from the first to the last, with the identity
/// its producer gave it.
///
/// The identity is the producer's own stable key, not the shape's position in the
/// frame (see `LaserShapeID`). Effects and the output stage may address a shape by
/// it; nothing in the stream itself depends on it, and nothing keeps it unique.
public struct Laser3DShape: Equatable, Sendable {
    public var id: LaserShapeID
    public var vertices: [LaserVertex]

    public init(id: LaserShapeID, vertices: [LaserVertex]) { self.id = id; self.vertices = vertices }
    public var isEmpty: Bool { vertices.isEmpty }

    /// One dark vertex at the centre of the scanner: what a source answers with when it
    /// cannot make its picture. Each read of it gives one dark centre sample, so a reader
    /// that keeps reading until it has the length it asked for gets that many.
    public static let blackCenter = Laser3DShape(id: 0, vertices: [LaserVertex(x: 0, y: 0, rgba: .zero, mode: .blank)])
}

/// A source of shapes in the front half of the pipeline (3D, `LaserVertex`).
///
/// Each `read` answers with the shapes of one frame, every one of them whole: a shape
/// is never split over two reads, and the end of the array is the end of the frame.
/// An empty array means there is nothing to draw now, not that the stream is over.
/// `read` never waits, so a real-time pump can call it. A source makes its frame on the
/// spot, from the absolute time it reads itself, and keeps no frame to repeat.
///
/// Everything after the projection is a `Laser2DStream` of scanner samples.
public protocol Laser3DStream: Sendable {
    mutating func read() -> [Laser3DShape]
}
