import Foundation
import simd

/// Settings for turning shape-space vertices into scanner samples: the camera, the
/// projection, the near/far planes the path is cut at, and how many dwell and blank
/// samples are put at each cut.
public struct LaserProjection: Equatable, Sendable {
    /// Shape space to camera space.
    public var camera: simd_double4x4
    /// Camera space to clip space.
    public var projection: simd_double4x4
    public var near: Double
    public var far: Double
    /// Samples held on the cut point where the path leaves or enters the view.
    public var dwell: Int
    /// Dark samples at the cut point, so the scanner can travel without drawing.
    public var blank: Int

    public init(camera: simd_double4x4 = matrix_identity_double4x4,
                projection: simd_double4x4,
                near: Double = 0.1, far: Double = 50,
                dwell: Int = 0, blank: Int = 0) {
        self.camera = camera; self.projection = projection
        self.near = near; self.far = far
        self.dwell = max(0, dwell); self.blank = max(0, blank)
    }

    /// Legacy's left-handed perspective matrix (X is mirrored, w = camera z).
    public static func perspective(fovxDegrees: Double, aspectRatio: Double = 1, near: Double, far: Double) -> simd_double4x4 {
        let xs = 1 / tan(fovxDegrees * 0.5 * .pi / 180)
        let ys = xs * aspectRatio
        return simd_double4x4(columns: (
            SIMD4(-xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, (far + near) / (far - near), 1),
            SIMD4(0, 0, -(2 * far * near) / (far - near), 0)))
    }
}

/// Projects `LaserVertex` paths to `LaserPoint`s the way Legacy's `zClipProjection`
/// did: a path that leaves the near/far range is cut on the plane and ends with
/// dwell then blank samples; one that comes back starts with blank then dwell
/// samples on the plane. Between the two nothing is drawn.
///
/// It keeps the previous vertex between calls, so a path can arrive in several
/// chunks. The path restarts (no segment is drawn across) where the shape
/// identity changes or a frame ends.
///
/// Projected coordinates beyond the scanner's -1...1 are clamped per component, as
/// Legacy's wire encoding did; the colour is `rgb * alpha` limited to 0...1.
public struct LaserProjector: LaserStage {
    public var settings: LaserProjection
    private var previous: SIMD4<Double>?
    private var previousRun: LaserShapeID?
    private var restartNext = false

    public init(_ settings: LaserProjection) { self.settings = settings }

    /// Forgets the previous vertex; the next one starts a new path.
    public mutating func reset() { previous = nil; previousRun = nil; restartNext = false }

    public mutating func project(_ chunk: LaserChunk<LaserVertex>) -> LaserChunk<LaserPoint> {
        let count = chunk.count
        var restarts = Set<Int>()
        if restartNext { restarts.insert(0) }
        restartNext = false
        for run in chunk.runs where !run.range.isEmpty {
            if run.id != previousRun { restarts.insert(run.range.lowerBound) }
            previousRun = run.id
        }
        for end in chunk.frameEnds {
            if end < count { restarts.insert(end) } else if end == count { restartNext = true }
        }

        var points: [LaserPoint] = []
        points.reserveCapacity(count)
        var starts = [Int](repeating: 0, count: count + 1)
        for (index, vertex) in chunk.elements.enumerated() {
            if restarts.contains(index) { previous = nil }
            starts[index] = points.count
            emit(vertex, into: &points)
        }
        starts[count] = points.count

        return LaserChunk(elements: points, carrying: chunk, starts: starts)
    }

    public mutating func process(_ chunk: LaserChunk<LaserVertex>) -> LaserChunk<LaserPoint> { project(chunk) }

    private func isInside(_ camera: SIMD4<Double>) -> Bool { camera.z > settings.near && camera.z < settings.far }

    private mutating func emit(_ vertex: LaserVertex, into points: inout [LaserPoint]) {
        let s = settings
        let cam = s.camera * vertex.position
        let color = SIMD3(vertex.rgba.x, vertex.rgba.y, vertex.rgba.z) * vertex.rgba.w
        defer { previous = cam }

        /// The scanner sample for a camera-space position, or nil if it does not project.
        func sample(_ position: SIMD4<Double>, _ mode: LaserPointMode) -> LaserPoint? {
            let clip = s.projection * position
            guard clip.w != 0 else { return nil }
            let ndc = clip / clip.w
            guard ndc.x.isFinite, ndc.y.isFinite else { return nil }
            func limit(_ v: Double, _ low: Double, _ high: Double) -> Float { v.isFinite ? Float(min(high, max(low, v))) : 0 }
            let rgb = mode == .blank ? SIMD3<Float>.zero
                : SIMD3(limit(color.x, 0, 1), limit(color.y, 0, 1), limit(color.z, 0, 1))
            return try? LaserPoint(xy: SIMD2(limit(ndc.x, -1, 1), limit(ndc.y, -1, 1)), rgb: rgb, mode: mode)
        }
        /// Where the segment between two camera positions crosses the plane z = `plane`.
        func cut(_ from: SIMD4<Double>, _ to: SIMD4<Double>, plane: Double) -> SIMD4<Double>? {
            let dz = to.z - from.z
            guard abs(dz) >= 1e-12 else { return nil }
            let t = (plane - from.z) / dz
            guard t >= 0, t <= 1 else { return nil }
            let at = from + (to - from) * t
            return SIMD4(at.x, at.y, plane, 1)
        }

        if !isInside(cam) {
            // Leaving the view: only a path that was inside has anything to finish.
            guard let last = previous, isInside(last),
                  let at = cut(last, cam, plane: cam.z < s.near ? s.near : s.far),
                  let end = sample(at, .normal) else { return }
            points.append(end)
            points.append(contentsOf: Array(repeating: end.dwelling(), count: s.dwell))
            points.append(contentsOf: Array(repeating: end.blanked(), count: s.blank))
        } else if let last = previous, !isInside(last), last.x.isFinite {
            // Coming back: travel dark to the cut, settle there, then draw.
            if let at = cut(cam, last, plane: last.z < s.near ? s.near : s.far), let start = sample(at, .normal) {
                points.append(contentsOf: Array(repeating: start.blanked(), count: s.blank))
                points.append(contentsOf: Array(repeating: start.dwelling(), count: s.dwell))
                points.append(start)
                if let here = sample(cam, vertex.mode) { points.append(here) }
            } else if let here = sample(cam, .blank) {
                points.append(here)
            }
        } else if let here = sample(cam, vertex.mode) {
            points.append(here)
        }
    }
}

/// A shape-space stream seen through a projection: what an output plays.
public struct LaserProjectedStream<Upstream: LaserStream>: LaserOutputStream where Upstream.Element == LaserVertex {
    public private(set) var upstream: Upstream
    public var projector: LaserProjector
    public let format: LaserStreamFormat

    public init(_ upstream: Upstream, projection: LaserProjection, rate: UInt32) {
        self.upstream = upstream
        projector = LaserProjector(projection)
        format = LaserStreamFormat(domain: .scanner, rate: rate)
    }

    public mutating func read(wanting count: Int) -> LaserChunk<LaserPoint> {
        projector.project(upstream.read(wanting: count))
    }
}
