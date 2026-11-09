import Foundation

/// Applies an output's safety masks to scanner samples: each sample's colour is
/// scaled by the masks' multiplier at its position, so light is dimmed or cut
/// wherever a mask says. It is meant to be applied last, after the resampler has
/// spaced the samples, so a mask edge is honoured at sample resolution. It never
/// moves, adds or drops a sample.
public struct LaserMasking: Sendable {
    public var masks: LaserMaskSettings

    public init(_ masks: LaserMaskSettings) { self.masks = masks }

    /// The same samples with the masks applied; nothing is added, dropped or moved.
    public func apply(_ points: [LaserPoint]) -> [LaserPoint] {
        guard masks.masks.contains(where: \.enabled) else { return points }
        var out = points
        for index in out.indices {
            let point = out[index]
            guard point.rgb != .zero else { continue }
            // Mask coordinates run 0...1 with the origin at the top left.
            let at = MaskPoint(Double((point.xy.x + 1) / 2), Double((1 - point.xy.y) / 2))
            let multiplier = Float(min(1, max(0, masks.multiplier(at: at))))
            if multiplier < 1 {
                out[index] = try! LaserPoint(xy: point.xy, rgb: point.rgb * multiplier, mode: point.mode)
            }
        }
        return out
    }
}
