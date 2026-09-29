import Foundation

/// A visual FX owns its playback state and painting.  The `.fx(...)` modifier
/// keeps these alive for as long as their host view remains in the tree.
public protocol FXPlayback: AnyObject {
    var finished: Bool { get }
    func step(now: Double)
    func draw(in rect: Rect, context: RenderContext)
}

/// A playback that replaces an older playback with the same key on its host.
/// Useful for continuously updated readouts such as a running tally.
public protocol ReplacingFXPlayback: FXPlayback {
    var replacementKey: String { get }
}

/// Opt an FX leaf into the implicit XView playback driver.
public protocol VFX: FX {
    func makePlayback(at point: Point, startedAt: Double) -> any FXPlayback
}

/// What a playback is born with. `environment` is the host's, so a leaf can
/// read app-injected values (an intensity, a palette) at the moment it starts.
public struct FXPlaybackContext {
    public var point: Point
    public var startedAt: Double
    public var environment: EnvironmentValues

    public init(point: Point, startedAt: Double, environment: EnvironmentValues) {
        self.point = point
        self.startedAt = startedAt
        self.environment = environment
    }
}

/// A `VFX` that wants the host environment when it starts. The sink prefers
/// this over `makePlayback(at:startedAt:)`; that method still has to exist
/// (it is `VFX`'s requirement) and defaults to an empty environment.
public protocol ContextualVFX: VFX {
    func makePlayback(in context: FXPlaybackContext) -> any FXPlayback
}

public extension ContextualVFX {
    func makePlayback(at point: Point, startedAt: Double) -> any FXPlayback {
        makePlayback(in: FXPlaybackContext(point: point, startedAt: startedAt,
                                           environment: EnvironmentValues()))
    }
}
