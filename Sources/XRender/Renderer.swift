/// Backend boundary for one compiled frame.
///
/// `XRender` owns the renderer-neutral frame model; platform packages provide
/// the concrete implementation that uploads it to Metal, WebGPU, or another
/// graphics API.
public protocol XRenderer: AnyObject {
    /// The device's best-effort frame-rate ceiling for the event-driven loop.
    var maximumFramesPerSecond: Double { get }

    func render(_ frame: CompiledFrame, time: Float)
}

public extension XRenderer {
    var maximumFramesPerSecond: Double { 60 }
}
