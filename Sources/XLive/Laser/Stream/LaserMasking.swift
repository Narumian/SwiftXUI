import Foundation

/// Applies an output's safety masks to a scanner stream: each sample's colour is
/// scaled by the masks' multiplier at its position, so light is dimmed or cut
/// wherever a mask says. It is meant to sit last in a chain, after the sampler has
/// spaced the samples, so a mask edge is honoured at sample resolution. It never
/// moves, adds or drops a sample, and leaves runs and frame ends as they were.
public struct LaserMasking: LaserStage {
    public var masks: LaserMaskSettings

    public init(_ masks: LaserMaskSettings) { self.masks = masks }

    public mutating func process(_ chunk: LaserChunk<LaserPoint>) -> LaserChunk<LaserPoint> {
        guard masks.masks.contains(where: \.enabled) else { return chunk }
        var out = chunk
        for index in out.elements.indices {
            let point = out.elements[index]
            guard point.rgb != .zero else { continue }
            // Mask coordinates run 0...1 with the origin at the top left.
            let at = MaskPoint(Double((point.xy.x + 1) / 2), Double((1 - point.xy.y) / 2))
            let multiplier = Float(min(1, max(0, masks.multiplier(at: at))))
            if multiplier < 1 {
                out.elements[index] = try! LaserPoint(xy: point.xy, rgb: point.rgb * multiplier, mode: point.mode)
            }
        }
        return out
    }
}
