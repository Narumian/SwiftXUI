import CWGPU

#if canImport(QuartzCore)
import QuartzCore

extension WGPURenderer {
    /// Makes the renderer read the drawable size straight from `layer`, so `isStale` and
    /// `render` can refuse frames laid out for a size the layer no longer has.
    public func trackDrawableSize(of layer: CAMetalLayer) {
        drawableSizeProvider = { [weak layer] in
            guard let size = layer?.drawableSize, size.width >= 1, size.height >= 1 else { return nil }
            return (UInt32(size.width.rounded()), UInt32(size.height.rounded()))
        }
    }
}
#endif
