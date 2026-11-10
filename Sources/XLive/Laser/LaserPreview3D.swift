import Foundation
import simd
import XUI

/// A 3D laser preview. It retains the source Laser3DBuffer and sends its
/// Float32 point payload and shape boundaries to the renderer without building
/// an intermediate vertex buffer or scanning points on the CPU.
public struct LaserPreview3D: XView, Sendable {
    private let source: Laser3DBuffer
    private let shapeRanges: [Range<Int>]
    private let matrix: [Float]

    public init(_ source: Laser3DBuffer, projection: LaserProjection) {
        self.source = source
        shapeRanges = source.shapes.map { Int($0.start)..<(Int($0.start) + Int($0.count)) }
        let m = projection.projection * projection.camera
        matrix = [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                  m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                  m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                  m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w].map(Float.init)
    }

    public var body: some XView {
        DrawLayer { rect, context in
            guard !self.shapeRanges.isEmpty,
                  let sink = context.canvas as? LaserPreviewSink else { return }
            sink.drawLaserPreview(vertices: self.source.vertexValues, modes: self.source.vertexModes,
                                  shapes: self.shapeRanges, matrix: self.matrix, in: rect)
        }
    }
}
