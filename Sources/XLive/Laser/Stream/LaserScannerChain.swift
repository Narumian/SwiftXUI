import Foundation

/// The whole path from shapes to scanner samples that every output shares, in the order
/// the zone applies it: mastering (in 3D, a placeholder for now), projection, then padding
/// (dwell and blank at the ends of each shape), corner dwell, and the resampler. Each stage is read from the
/// `LaserScannerSettings` in `live` before every frame, so a setting that changes
/// while the chain plays takes effect on the next frame, without a rebuild.
public struct LaserScannerChain<Source: Laser3DStream>: Laser2DStream {
    public private(set) var source: Source
    public let rate: UInt32?
    /// Stops a source whose frames all project to nothing from being asked forever.
    public var maximumReads = 8
    private let live: LaserLive<LaserScannerSettings>
    private let template: LaserProjection
    private let mastering: LaserLive<LaserMastering>
    private var projector: LaserProjector
    private var padding: LaserDwellBlank
    private var corners: LaserCornerDwell
    private var resampler: LaserResampler

    public init(_ source: Source, projection template: LaserProjection, live: LaserLive<LaserScannerSettings>,
                mastering: LaserLive<LaserMastering> = LaserLive(LaserMastering()), rate: UInt32 = 30000) {
        self.source = source; self.template = template; self.live = live; self.mastering = mastering; self.rate = rate
        let s = live.value
        projector = LaserProjector(template)
        padding = LaserDwellBlank(dwell: s.paddingDwell, blank: s.paddingBlank)
        corners = LaserCornerDwell(maximum: s.cornerDwell, thresholdDegrees: s.cornerThresholdDegrees)
        resampler = LaserResampler(minimumStep: s.minimumStep, maximumStep: s.maximumStep)
    }

    /// One frame of the source through the stages. Reads again when a whole frame came out
    /// as nothing (every shape out of view, say), so an empty answer means the source has
    /// nothing now and not that this frame happened to be hidden.
    public mutating func read() -> [Laser2DShape] {
        for _ in 0..<max(1, maximumReads) {
            let shapes = source.read()
            if shapes.isEmpty { return [] }
            let out = process(shapes)
            if !out.isEmpty { return out }
        }
        return []
    }

    /// The shapes through the stages with the settings as they are now.
    public mutating func process(_ shapes: [Laser3DShape]) -> [Laser2DShape] {
        tune(live.value)
        return resampler.process(corners.process(padding.process(projector.project(mastering.value.process(shapes)))))
    }

    private mutating func tune(_ s: LaserScannerSettings) {
        var projection = template
        projection.dwell = max(0, s.paddingDwell); projection.blank = max(0, s.paddingBlank); projection.screen = s.screen
        if projector.settings != projection { projector.settings = projection }
        padding.dwell = max(0, s.paddingDwell); padding.blank = max(0, s.paddingBlank)
        corners.maximum = max(0, s.cornerDwell); corners.thresholdDegrees = min(180, max(0, s.cornerThresholdDegrees))
        resampler.maximumStep = max(1e-9, s.maximumStep); resampler.minimumStep = max(0, s.minimumStep)
    }
}
