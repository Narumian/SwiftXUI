/// Backend boundary for one compiled frame.
///
/// `XRender` owns the renderer-neutral frame model; platform packages provide
/// the concrete implementation that uploads it to Metal, WebGPU, or another
/// graphics API.
public protocol XRenderer: AnyObject {
    func render(_ frame: CompiledFrame, time: Float)
}

/// Optional texture capability used by dynamic fonts and other image assets.
public protocol XTextureRenderer: XRenderer {
    func registerTexture(_ id: TextureID, rgba: [UInt8], width: Int, height: Int)
    func updateTexture(_ id: TextureID, rgba: [UInt8], y: Int, width: Int, height: Int)
}
