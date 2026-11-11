import Foundation

public struct LaserScannerChain: Laser2DStream {
    private let source: LaserLive<Laser3DBuffer>
    public let rate: UInt32?
    private let live: LaserLive<LaserScannerSettings>
    private let template: LaserProjection
    private let mastering: LaserLive<LaserMastering>
    private var projector: LaserProjector
    private var padding: LaserDwellBlank
    private var corners: LaserCornerDwell
    private var resampler: LaserResampler

    public init(_ source: LaserLive<Laser3DBuffer>, projection template: LaserProjection, live: LaserLive<LaserScannerSettings>,
                mastering: LaserLive<LaserMastering> = LaserLive(LaserMastering()), rate: UInt32 = 30000) {
        self.source = source; self.template = template; self.live = live; self.mastering = mastering; self.rate = rate
        let s = live.value
        projector = LaserProjector(template)
        padding = LaserDwellBlank(dwell: s.paddingDwell, blank: s.paddingBlank)
        corners = LaserCornerDwell(maximum: s.cornerDwell, thresholdDegrees: s.cornerThresholdDegrees)
        resampler = LaserResampler(minimumStep: s.minimumStep, maximumStep: s.maximumStep)
    }

    public mutating func read() -> [Laser2DShape] {
        process(source.value)
    }

    public mutating func process(_ shapes: Laser3DBuffer) -> [Laser2DShape] {
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
