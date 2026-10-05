import Foundation
import XShader

/// Phases of the X3D path that can be timed by `X3DCostProbe`.
public enum X3DCostPhase: String, Sendable, Hashable, CaseIterable {
    case walk
    case assemble
    case encode
}

/// Structural cost of one lowered `X3DGraph` (no GPU required).
public struct X3DGraphMetrics: Sendable, Equatable {
    public var resources: Int
    public var bufferBytes: Int
    public var textures: Int
    public var passes: Int
    public var computes: Int
    public var draws: Int
    public var blits: Int
    public var views: Int
    public var planes: Int

    public init(
        resources: Int = 0, bufferBytes: Int = 0, textures: Int = 0,
        passes: Int = 0, computes: Int = 0, draws: Int = 0,
        blits: Int = 0, views: Int = 0, planes: Int = 0
    ) {
        self.resources = resources
        self.bufferBytes = bufferBytes
        self.textures = textures
        self.passes = passes
        self.computes = computes
        self.draws = draws
        self.blits = blits
        self.views = views
        self.planes = planes
    }

    public init(_ graph: X3DGraph) {
        var metrics = X3DGraphMetrics()
        metrics.resources = graph.resources.count
        for resource in graph.resources {
            switch resource {
            case .buffer(_, let byteCount, _):
                metrics.bufferBytes += byteCount
            case .texture:
                metrics.textures += 1
            }
        }
        metrics.passes = graph.passes.count
        for pass in graph.passes {
            switch pass {
            case .compute:
                metrics.computes += 1
            case .render(let render):
                for item in render.items {
                    switch item {
                    case .draw: metrics.draws += 1
                    case .blit: metrics.blits += 1
                    case .view: metrics.views += 1
                    case .plane: metrics.planes += 1
                    }
                }
            }
        }
        self = metrics
    }
}

/// GPU resource churn observed during one encode (or simulated in tests).
public struct X3DResourceChurn: Sendable, Equatable {
    public var reused: Int
    public var created: Int
    public var released: Int
    public var bufferBytesUploaded: Int

    public init(reused: Int = 0, created: Int = 0, released: Int = 0, bufferBytesUploaded: Int = 0) {
        self.reused = reused
        self.created = created
        self.released = released
        self.bufferBytesUploaded = bufferBytesUploaded
    }

    public static func += (lhs: inout X3DResourceChurn, rhs: X3DResourceChurn) {
        lhs.reused += rhs.reused
        lhs.created += rhs.created
        lhs.released += rhs.released
        lhs.bufferBytesUploaded += rhs.bufferBytesUploaded
    }
}

/// One collected sample: phase timings plus graph / churn counters.
public struct X3DCostSample: Sendable, Equatable {
    public var nanoseconds: [X3DCostPhase: UInt64]
    public var metrics: X3DGraphMetrics
    public var churn: X3DResourceChurn

    public init(
        nanoseconds: [X3DCostPhase: UInt64] = [:],
        metrics: X3DGraphMetrics = X3DGraphMetrics(),
        churn: X3DResourceChurn = X3DResourceChurn()
    ) {
        self.nanoseconds = nanoseconds
        self.metrics = metrics
        self.churn = churn
    }

    public func nanoseconds(for phase: X3DCostPhase) -> UInt64 {
        nanoseconds[phase] ?? 0
    }
}

/// Opt-in collector for walk / assemble / encode timings and resource churn.
///
/// Disabled by default so production frames pay only an `isEnabled` check.
/// Enable around a bench or debug HUD; read `last` after the frame completes.
public final class X3DCostProbe: @unchecked Sendable {
    public static let shared = X3DCostProbe()

    public var isEnabled = false
    public private(set) var last = X3DCostSample()
    private var building = X3DCostSample()
    private let clock = ContinuousClock()

    public init() {}

    public func reset() {
        building = X3DCostSample()
        last = X3DCostSample()
    }

    public func beginFrame() {
        guard isEnabled else { return }
        building = X3DCostSample()
    }

    public func endFrame() {
        guard isEnabled else { return }
        last = building
    }

    public func begin(_ phase: X3DCostPhase) -> ContinuousClock.Instant? {
        guard isEnabled else { return nil }
        return clock.now
    }

    public func end(_ phase: X3DCostPhase, started: ContinuousClock.Instant?) {
        guard isEnabled, let started else { return }
        let delta = started.duration(to: clock.now)
        let ns = UInt64(delta.components.seconds) &* 1_000_000_000
            &+ UInt64(max(0, delta.components.attoseconds / 1_000_000_000))
        building.nanoseconds[phase, default: 0] += ns
    }

    public func record(metrics: X3DGraphMetrics) {
        guard isEnabled else { return }
        building.metrics = metrics
    }

    public func record(churn: X3DResourceChurn) {
        guard isEnabled else { return }
        building.churn += churn
    }
}

public extension X3DGraph {
    /// Structural cost profile for authors and benches.
    var metrics: X3DGraphMetrics { X3DGraphMetrics(self) }
}

/// Author-facing contracts for plane rasterisation resolution.
public enum X3DPlanePolicy {
    /// Layout points per world unit (`planeSize / pointsPerWorldUnit` spans the panel).
    public static let pointsPerWorldUnit: Float = 100

    public static func worldSize(layoutPoints: SIMD2<Float>) -> SIMD2<Float> {
        layoutPoints / pointsPerWorldUnit
    }

    public static func halfExtents(layoutPoints: SIMD2<Float>) -> SIMD2<Float> {
        worldSize(layoutPoints: layoutPoints) / 2
    }

    /// Offscreen plane targets match the full framebuffer; UV selects the
    /// letterboxed authoring region compiled into that target.
    public static let offscreenMatchesFramebuffer = true
}

/// When a declared buffer must be recreated / reuploaded on the GPU.
public enum X3DBufferUploadPolicy {
    /// `true` when the existing GPU buffer cannot be reused as-is.
    ///
    /// Reuse requires equal `byteCount` and equal `contents` (including both
    /// `nil`). Any contents change triggers a full recreate + upload — there
    /// is no partial or hashed delta path yet.
    public static func needsReupload(
        existingByteCount: Int,
        existingContents: [Float]?,
        byteCount: Int,
        contents: [Float]?
    ) -> Bool {
        existingByteCount != byteCount || existingContents != contents
    }

    public static func needsReupload(
        existingByteCount: Int,
        existingContents: [Float]?,
        resource: X3DResource
    ) -> Bool {
        guard case .buffer(_, let byteCount, let contents) = resource else { return true }
        return needsReupload(
            existingByteCount: existingByteCount,
            existingContents: existingContents,
            byteCount: byteCount,
            contents: contents
        )
    }
}
