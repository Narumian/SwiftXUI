import Foundation

/// How one output's scanner wants its drawing prepared. These are the settings of
/// the output chain that belong to the scanner and its taste, not to a shape: the
/// holds that let the galvanometers settle, how corners and screen edges are
/// treated, and how finely moves are spaced. They are saved with the output.
public struct LaserScannerProfile: Codable, Equatable, Sendable {
    /// Samples held at each end of a shape, and where a path is cut (view or screen).
    public var paddingDwell: Int
    /// Dark samples before a shape and where a path returns from a cut.
    public var paddingBlank: Int
    public var screen: LaserScreenMode
    /// Dwell samples for a corner that turns all the way back; sharper turns get more.
    public var cornerDwell: Int
    /// Corners that turn less than this many degrees are not held.
    public var cornerThresholdDegrees: Double
    /// Longest gap between drawn samples, in scanner units (the full width is 2).
    public var maximumStep: Double
    /// Drawn samples closer than this are merged.
    public var minimumStep: Double

    public init(paddingDwell: Int = 3, paddingBlank: Int = 3, screen: LaserScreenMode = .blanking,
                cornerDwell: Int = 8, cornerThresholdDegrees: Double = 20,
                maximumStep: Double = 0.04, minimumStep: Double = 0) {
        self.paddingDwell = paddingDwell; self.paddingBlank = paddingBlank; self.screen = screen
        self.cornerDwell = cornerDwell; self.cornerThresholdDegrees = cornerThresholdDegrees
        self.maximumStep = maximumStep; self.minimumStep = minimumStep
    }

    private enum CodingKeys: String, CodingKey {
        case paddingDwell, paddingBlank, screen, cornerDwell, cornerThresholdDegrees, maximumStep, minimumStep
    }
    /// Missing keys keep their defaults, so a profile saved by an older build still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LaserScannerProfile()
        paddingDwell = try c.decodeIfPresent(Int.self, forKey: .paddingDwell) ?? d.paddingDwell
        paddingBlank = try c.decodeIfPresent(Int.self, forKey: .paddingBlank) ?? d.paddingBlank
        screen = try c.decodeIfPresent(LaserScreenMode.self, forKey: .screen) ?? d.screen
        cornerDwell = try c.decodeIfPresent(Int.self, forKey: .cornerDwell) ?? d.cornerDwell
        cornerThresholdDegrees = try c.decodeIfPresent(Double.self, forKey: .cornerThresholdDegrees) ?? d.cornerThresholdDegrees
        maximumStep = try c.decodeIfPresent(Double.self, forKey: .maximumStep) ?? d.maximumStep
        minimumStep = try c.decodeIfPresent(Double.self, forKey: .minimumStep) ?? d.minimumStep
    }

    /// The whole output chain for one output: shapes in, scanner samples out.
    /// Padding, projection (with this profile's cut and screen handling), corner
    /// dwell, sampling and the output's safety masks, in that order.
    public func output<Shapes: LaserStream>(from shapes: Shapes, projection template: LaserProjection,
                                            masks: LaserMaskSettings, rate: UInt32 = 30000) -> some LaserOutputStream
    where Shapes.Element == LaserVertex {
        var projection = template
        projection.dwell = max(0, paddingDwell); projection.blank = max(0, paddingBlank); projection.screen = screen
        let shapeFormat = LaserStreamFormat(domain: .shapes), scanner = LaserStreamFormat(domain: .scanner, rate: rate)
        let padded = LaserStagedStream(shapes, stage: LaserDwellBlank(dwell: paddingDwell, blank: paddingBlank), format: shapeFormat)
        let projected = LaserStagedStream(padded, stage: LaserProjector(projection), format: scanner)
        let cornered = LaserStagedStream(projected, stage: LaserCornerDwell(maximum: cornerDwell, thresholdDegrees: cornerThresholdDegrees), format: scanner)
        let sampled = LaserStagedStream(cornered, stage: LaserSampler(minimumStep: minimumStep, maximumStep: maximumStep), format: scanner)
        return LaserStagedStream(sampled, stage: LaserMasking(masks), format: scanner)
    }
}

/// One adjustable number of a `LaserScannerProfile`, with what a control needs to
/// show it: a label, a range, whether it is whole, and how to read and write it.
public enum LaserScannerParameter: String, CaseIterable, Codable, Sendable, Identifiable {
    case paddingDwell, paddingBlank, cornerDwell, cornerThreshold, maximumStep, minimumStep

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .paddingDwell: "PADDING DWELL"
        case .paddingBlank: "PADDING BLANK"
        case .cornerDwell: "CORNER DWELL"
        case .cornerThreshold: "CORNER ANGLE"
        case .maximumStep: "MAX STEP"
        case .minimumStep: "MIN STEP"
        }
    }
    public var range: ClosedRange<Double> {
        switch self {
        case .paddingDwell, .paddingBlank: 0...100
        case .cornerDwell: 0...30
        case .cornerThreshold: 0...90
        case .maximumStep: 0.005...0.2
        case .minimumStep: 0...0.05
        }
    }
    public var isWhole: Bool {
        switch self { case .paddingDwell, .paddingBlank, .cornerDwell: true; default: false }
    }
    public var defaultValue: Double { value(in: LaserScannerProfile()) }

    public func value(in profile: LaserScannerProfile) -> Double {
        switch self {
        case .paddingDwell: Double(profile.paddingDwell)
        case .paddingBlank: Double(profile.paddingBlank)
        case .cornerDwell: Double(profile.cornerDwell)
        case .cornerThreshold: profile.cornerThresholdDegrees
        case .maximumStep: profile.maximumStep
        case .minimumStep: profile.minimumStep
        }
    }
    /// Writes `value`, limited to the range and rounded if the parameter is whole.
    public func set(_ value: Double, in profile: inout LaserScannerProfile) {
        guard value.isFinite else { return }
        let limited = min(range.upperBound, max(range.lowerBound, value))
        switch self {
        case .paddingDwell: profile.paddingDwell = Int(limited.rounded())
        case .paddingBlank: profile.paddingBlank = Int(limited.rounded())
        case .cornerDwell: profile.cornerDwell = Int(limited.rounded())
        case .cornerThreshold: profile.cornerThresholdDegrees = limited
        case .maximumStep: profile.maximumStep = limited
        case .minimumStep: profile.minimumStep = limited
        }
    }
    /// 0...1 across the range.
    public func normalized(in profile: LaserScannerProfile) -> Double {
        (value(in: profile) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
    public func setNormalized(_ n: Double, in profile: inout LaserScannerProfile) {
        guard n.isFinite else { return }
        set(range.lowerBound + min(1, max(0, n)) * (range.upperBound - range.lowerBound), in: &profile)
    }
    public func display(_ profile: LaserScannerProfile) -> String {
        let v = value(in: profile)
        switch self {
        case .cornerThreshold: return "\(Int(v.rounded()))°"
        case .maximumStep, .minimumStep: return String(format: "%.3f", v)
        default: return "\(Int(v.rounded()))"
        }
    }
}
