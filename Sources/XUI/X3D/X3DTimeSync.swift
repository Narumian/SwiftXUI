import Foundation

/// Documents and bridges the two presentation clocks used with X3D:
///
/// - **FX / Animation** consume absolute host seconds via `EnvironmentValues.fxTime`
///   (`XUIHost.render(_:time:)` / `XAppSession.render(time:)`).
/// - **GPU `x3d.time`** consumes epoch-relative seconds via
///   `XRenderer.render(_:time:)` (see `XAppDriver.frame(at:)`).
///
/// Feed both from the same display-link timestamp; keep one `X3DTimeSync` for
/// the session so FX motion and shader time advance together.
public struct X3DTimeSync: Sendable, Equatable {
    public private(set) var epoch: Double?

    public init(epoch: Double? = nil) {
        self.epoch = epoch
    }

    /// Absolute seconds for `fxTime` / animation (pass through).
    public func fxTime(at absolute: Double) -> Double { absolute }

    /// Epoch-relative seconds for `XRenderer.render(_:time:)` / `x3d.time`.
    public mutating func rendererTime(at absolute: Double) -> Float {
        let start = epoch ?? absolute
        epoch = start
        return Float(absolute - start)
    }
}
