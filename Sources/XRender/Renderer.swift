/// Backend boundary for one compiled frame.
///
/// `XRender` owns the renderer-neutral frame model; platform packages provide
/// the concrete implementation that uploads it to Metal, WebGPU, or another
/// graphics API.
public protocol XRenderer: AnyObject {
    func render(_ frame: CompiledFrame, time: Float)
}
