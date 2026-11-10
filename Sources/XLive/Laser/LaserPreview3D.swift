import Foundation
import simd
import XUI

/// A 3D laser preview. It retains the source Laser3DBuffer and sends its
/// Float32 point payload and shape boundaries to the renderer without building
/// an intermediate vertex buffer or scanning points on the CPU.
public struct LaserPreview3D: XView, Sendable {
    private let draw: @Sendable (Rect, RenderContext) -> Void

    public init(_ source: Laser3DBuffer, projection: LaserProjection) {
        let ranges = Self.ranges(of: source)
        let matrix = Self.matrix(for: projection)
        draw = { rect, context in
            guard !ranges.isEmpty, let sink = context.canvas as? LaserPreviewSink else { return }
            sink.drawLaserPreview(vertices: source.vertexValues, modes: source.vertexModes,
                                  shapes: ranges, matrix: matrix, in: rect)
        }
    }

    /// Read the latest geometry each time the preview paints. The layout can
    /// stay in place while the source publishes new buffers.
    public init(projection: LaserProjection, source: @escaping @Sendable () -> Laser3DBuffer) {
        let matrix = Self.matrix(for: projection)
        draw = { rect, context in
            guard let sink = context.canvas as? LaserPreviewSink else { return }
            let buffer = source()
            guard !buffer.shapes.isEmpty else { return }
            sink.drawLaserPreview(vertices: buffer.vertexValues, modes: buffer.vertexModes,
                                  shapes: Self.ranges(of: buffer), matrix: matrix, in: rect)
        }
    }

    private static func ranges(of source: Laser3DBuffer) -> [Range<Int>] {
        source.shapes.map { Int($0.start)..<(Int($0.start) + Int($0.count)) }
    }

    private static func matrix(for projection: LaserProjection) -> [Float] {
        let m = projection.projection * projection.camera
        return [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w].map(Float.init)
    }

    public var body: some XView {
        DrawLayer(draw)
    }
}
