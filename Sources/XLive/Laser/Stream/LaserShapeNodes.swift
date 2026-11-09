import XUI

/// Makes shapes in the front half of the pipeline (3D, `LaserVertex`). It takes no input.
///
/// State and time move only in `update(context:)`, as for any `XLive`. `process` answers
/// with the shapes as they stand after the last update, so asking twice in one tick gives
/// the same answer.
///
/// What it returns is the whole shapes of one frame, each a `Laser3DShape` from end to end.
/// An empty array means there is nothing to draw now.
public protocol LaserGeometry: XLive {
    func process(_ input: Void) -> [Laser3DShape]
}

/// Changes shapes in the front half of the pipeline (3D, `LaserVertex`).
///
/// It may add or drop shapes (copies, say); a copy is a shape of its own and takes the ID
/// its maker gives it. It does not pad with dwell or blank samples, and it does not put
/// blank vertices between shapes: moving the beam from one shape to the next is the
/// back half's job.
///
/// Like `LaserGeometry`, it keeps state and time in `update(context:)` and `process` does
/// not change the node.
public protocol LaserEffect: XLive {
    func process(_ input: [Laser3DShape]) -> [Laser3DShape]
}

/// A node with no interface of its own, like Legacy's default `viewbody`.
public extension LaserGeometry {
    var body: some XView { EmptyView() }
}

public extension LaserEffect {
    var body: some XView { EmptyView() }
}
