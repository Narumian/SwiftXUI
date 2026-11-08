import Foundation
import simd

/// What happens to a path where it leaves the scanner's -1...1 square.
public enum LaserScreenMode: Sendable, Equatable {
    /// Nothing special: coordinates beyond the square are clamped to its edge, so a
    /// shape that runs off the screen is drawn squashed along the edge. (Legacy's
    /// "OOScreen" switch on.)
    case clamp
    /// The path is cut at the edge. It leaves with the dwell and blank samples and
    /// comes back with blank then dwell samples; nothing is output while it is
    /// outside, so the scanner jumps from where it left to where it returns.
    /// (Legacy's "OOScreen" switch off.)
    case cut
    /// Only the light goes out. The path is not cut: the scanner keeps following it,
    /// held on the edge while it is outside, so the scan keeps its rhythm. One dark
    /// sample is added where the path crosses the edge; no dwell or blank padding.
    case blanking
    /// `blanking`, with the `dwell` and `blank` padding added at each crossing.
    case blankingWithPadding
}

/// Settings for turning shape-space vertices into scanner samples: the camera, the
/// projection, the near/far planes the path is cut at, how many dwell and blank
/// samples are put at each cut, and what happens off the screen.
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
    public var screen: LaserScreenMode

    public init(camera: simd_double4x4 = matrix_identity_double4x4,
                projection: simd_double4x4,
                near: Double = 0.1, far: Double = 50,
                dwell: Int = 0, blank: Int = 0,
                screen: LaserScreenMode = .clamp) {
        self.camera = camera; self.projection = projection
        self.near = near; self.far = far
        self.dwell = max(0, dwell); self.blank = max(0, blank)
        self.screen = screen
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
/// samples on the plane. Between the two nothing is drawn. What then happens at the
/// edge of the scanner's square is up to `LaserProjection.screen`.
///
/// It keeps the previous vertex between calls, so a path can arrive in several
/// chunks. The path restarts (no segment is drawn across) where the shape
/// identity changes or a frame ends.
///
/// The colour is `rgb * alpha` limited to 0...1.
public struct LaserProjector: LaserStage {
    public var settings: LaserProjection
    private var previous: SIMD4<Double>?
    private var previousRun: LaserShapeID?
    private var restartNext = false
    /// The last sample before the screen step, still beyond the square if it was.
    private var screenPrevious: Sample?

    public init(_ settings: LaserProjection) { self.settings = settings }

    /// Forgets the previous vertex; the next one starts a new path.
    public mutating func reset() { previous = nil; screenPrevious = nil; previousRun = nil; restartNext = false }

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
        var samples: [Sample] = []
        for (index, vertex) in chunk.elements.enumerated() {
            if restarts.contains(index) { previous = nil; screenPrevious = nil }
            starts[index] = points.count
            samples.removeAll(keepingCapacity: true)
            project(vertex, into: &samples)
            for sample in samples { screen(sample, into: &points) }
        }
        starts[count] = points.count
        return LaserChunk(elements: points, carrying: chunk, starts: starts)
    }

    public mutating func process(_ chunk: LaserChunk<LaserVertex>) -> LaserChunk<LaserPoint> { project(chunk) }

    // MARK: Samples

    /// A projected position before it is limited to the square.
    private struct Sample {
        var xy: SIMD2<Double>
        var rgb: SIMD3<Float>
        var mode: LaserPointMode

        func with(mode: LaserPointMode, dark: Bool = false) -> Sample {
            Sample(xy: xy, rgb: dark ? .zero : rgb, mode: mode)
        }
        var blanked: Sample { with(mode: .blank, dark: true) }
        var dwelling: Sample { with(mode: .dwell) }
        var darkened: Sample { Sample(xy: xy, rgb: .zero, mode: mode) }
        func moved(to xy: SIMD2<Double>) -> Sample { Sample(xy: xy, rgb: rgb, mode: mode) }

        /// Limited to the square; nil if it does not project to a finite place.
        var point: LaserPoint? {
            guard xy.x.isFinite, xy.y.isFinite else { return nil }
            let clamped = SIMD2(Float(min(1, max(-1, xy.x))), Float(min(1, max(-1, xy.y))))
            return try? LaserPoint(xy: clamped, rgb: rgb, mode: mode)
        }
    }

    // MARK: Near and far

    private func isInside(_ camera: SIMD4<Double>) -> Bool { camera.z > settings.near && camera.z < settings.far }

    private mutating func project(_ vertex: LaserVertex, into samples: inout [Sample]) {
        let s = settings
        let cam = s.camera * vertex.position
        let color = SIMD3(vertex.rgba.x, vertex.rgba.y, vertex.rgba.z) * vertex.rgba.w
        defer { previous = cam }

        /// The sample for a camera-space position, or nil if it does not project.
        func sample(_ position: SIMD4<Double>, _ mode: LaserPointMode) -> Sample? {
            let clip = s.projection * position
            guard clip.w != 0 else { return nil }
            let ndc = clip / clip.w
            guard ndc.x.isFinite, ndc.y.isFinite else { return nil }
            func limit(_ v: Double) -> Float { v.isFinite ? Float(min(1, max(0, v))) : 0 }
            let rgb = mode == .blank ? SIMD3<Float>.zero : SIMD3(limit(color.x), limit(color.y), limit(color.z))
            return Sample(xy: SIMD2(ndc.x, ndc.y), rgb: rgb, mode: mode)
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
            samples.append(end)
            samples.append(contentsOf: Array(repeating: end.dwelling, count: s.dwell))
            samples.append(contentsOf: Array(repeating: end.blanked, count: s.blank))
        } else if let last = previous, !isInside(last), last.x.isFinite {
            // Coming back: travel dark to the cut, settle there, then draw.
            if let at = cut(cam, last, plane: last.z < s.near ? s.near : s.far), let start = sample(at, .normal) {
                samples.append(contentsOf: Array(repeating: start.blanked, count: s.blank))
                samples.append(contentsOf: Array(repeating: start.dwelling, count: s.dwell))
                samples.append(start)
                if let here = sample(cam, vertex.mode) { samples.append(here) }
            } else if let here = sample(cam, .blank) {
                samples.append(here)
            }
        } else if let here = sample(cam, vertex.mode) {
            samples.append(here)
        }
    }

    // MARK: The square

    /// A little over 1 so a point meant to sit on the edge is not thrown out by rounding.
    private static let limit = 1 + 1e-6
    private static func isInside(_ xy: SIMD2<Double>) -> Bool { abs(xy.x) <= limit && abs(xy.y) <= limit }

    /// Where a straight move from `inside` towards `outside` leaves the square.
    private static func edge(from inside: SIMD2<Double>, toward outside: SIMD2<Double>) -> SIMD2<Double> {
        let d = outside - inside
        var t = 1.0
        for axis in 0..<2 where d[axis] != 0 {
            let bound = d[axis] > 0 ? 1.0 : -1.0
            t = min(t, max(0, (bound - inside[axis]) / d[axis]))
        }
        let at = inside + d * t
        return SIMD2(min(1, max(-1, at.x)), min(1, max(-1, at.y)))
    }

    private mutating func screen(_ sample: Sample, into points: inout [LaserPoint]) {
        func put(_ s: Sample, _ times: Int = 1) {
            guard times > 0, let p = s.point else { return }
            points.append(contentsOf: Array(repeating: p, count: times))
        }
        let mode = settings.screen
        guard mode != .clamp else { put(sample); return }

        // `cut` leaves nothing behind while outside; the blanking modes keep the
        // scanner moving, dark, on the edge. `cut` and `blankingWithPadding` pad.
        let followsOutside = mode != .cut
        let pads = mode != .blanking
        let dwell = settings.dwell, blank = settings.blank
        defer { screenPrevious = sample }

        let inside = Self.isInside(sample.xy)
        guard let last = screenPrevious else {
            if inside { put(sample) } else if followsOutside { put(sample.darkened) }
            return
        }
        switch (Self.isInside(last.xy), inside) {
        case (true, true):
            put(sample)
        case (true, false):
            let leaving = sample.moved(to: Self.edge(from: last.xy, toward: sample.xy))
            put(leaving)
            if pads { put(leaving.dwelling, dwell) }
            put(leaving.blanked, followsOutside ? 1 : min(blank, 1))
            if followsOutside { put(sample.darkened) }
        case (false, true):
            let entering = sample.moved(to: Self.edge(from: sample.xy, toward: last.xy))
            put(entering.blanked, pads ? (followsOutside ? max(1, blank) : blank) : 1)
            if pads { put(entering.dwelling, dwell) }
            put(entering)
            put(sample)
        case (false, false):
            if followsOutside { put(sample.darkened) }
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
