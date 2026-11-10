import XRender

/// Pixel size of the color attachment a render pass draws into.
///
/// Scissors and viewports must lie inside the attachment (Metal asserts it), and the
/// attachments of one frame do not all share a size: the swapchain drawable follows
/// the window while the scene, shader-layer and plane textures follow the configured
/// size, and the two disagree for a frame or more during a live resize. So every pass
/// clamps to the size of the attachment it is actually drawing into, never to a size
/// remembered from another target.
struct PassSize: Equatable {
    var width: UInt32
    var height: UInt32

    /// `rect` cut to this size, or the whole attachment when `rect` is nil. An
    /// origin outside the attachment gives an empty rect at the edge.
    func clamp(_ rect: PixelRect?) -> (x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
        guard let rect else { return (0, 0, width, height) }
        return clamp(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    func clamp(x: UInt32, y: UInt32, width rectWidth: UInt32, height rectHeight: UInt32)
        -> (x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
        let clampedX = min(x, width)
        let clampedY = min(y, height)
        return (clampedX, clampedY, min(rectWidth, width - clampedX), min(rectHeight, height - clampedY))
    }
}
