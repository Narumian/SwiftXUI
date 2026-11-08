import XUI

/// Makes shapes in the front half of the pipeline (3D, `LaserVertex`). It takes no input.
///
/// State and time move only in `update(context:)`, as for any `XLive`. `process` answers
/// with the shapes as they stand after the last update, so asking twice in one tick gives
/// the same answer.
///
/// What it returns is a list of whole shapes: a run holds one shape from end to end and a
/// shape is not split over runs. `LaserDwellBlank` and `LaserCornerDwell` depend on this.
/// An empty chunk means there is nothing to draw now.
///
/// `process(_:)` is shaped as a node with `Input == Void` and `Output == LaserChunk<LaserVertex>`
/// so that a domain-free node protocol can later be lifted out of it without touching
/// the conforming types.
public protocol LaserGeometry: XLive {
    func process(_ input: Void) -> LaserChunk<LaserVertex>
}

/// Changes shapes in the front half of the pipeline (3D, `LaserVertex`).
///
/// It may add or drop shapes (copies, say) and cuts the runs of what it adds. Two runs of
/// the same ID that touch are joined by `LaserChunk.append`, so an effect that makes copies
/// either gives each copy its own ID or builds the runs without `append`.
///
/// It does not pad with dwell or blank samples. Between copies it puts blank vertices and
/// leaves the padding at the ends of each run to `LaserDwellBlank`.
///
/// Like `LaserGeometry`, it keeps state and time in `update(context:)` and `process` does
/// not change the node.
public protocol LaserEffect: XLive {
    func process(_ input: LaserChunk<LaserVertex>) -> LaserChunk<LaserVertex>
}

/// A node with no interface of its own, like Legacy's default `viewbody`.
public extension LaserGeometry {
    var body: some XView { EmptyView() }
}

public extension LaserEffect {
    var body: some XView { EmptyView() }
}
