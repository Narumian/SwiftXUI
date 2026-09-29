import Foundation
import SwiftXUI

// Measures the automatic-identity mechanism's real per-frame cost before
// deciding whether the existential-avoiding `lower(_:)` redesign is worth
// pursuing. Always run `-c release` — debug numbers are not representative.

final class NullCanvas: XCanvas {
    func fillRect(_ rect: Rect, color: XColorValue) {}
    func fillRoundedRect(_ rect: Rect, cornerRadius: Double, color: XColorValue) {}
    func strokeRoundedRect(_ rect: Rect, cornerRadius: Double, color: XColorValue, lineWidth: Double) {}
    func fillEllipse(in rect: Rect, color: XColorValue) {}
    func fillPath(_ path: Path, in rect: Rect, color: XColorValue) {}
    func strokePath(_ path: Path, in rect: Rect, color: XColorValue, lineWidth: Double) {}
    func drawImage(_ source: ImageSource, in rect: Rect, opacity: Double) {}
    func drawText(_ string: String, in rect: Rect, fontSize: Double, font: TextFont,
                 color: XColorValue, alignment: HorizontalAlignment, outline: TextOutline?) {}
    func measureText(_ string: String, fontSize: Double, font: TextFont) -> Size { .zero }
    func pushClip(_ rect: Rect) {}
    func popClip() {}
    func pushTransform(_ transform: XTransform) {}
    func popTransform() {}
}

func report(_ label: String, iterations: Int, _ body: () -> Void) {
    let clock = ContinuousClock()
    let elapsed = clock.measure { for _ in 0..<iterations { body() } }
    let perCall = elapsed / iterations
    print("\(label): \(iterations) iters in \(elapsed) → \(perCall)/call")
}

// MARK: - trees

private struct PlainCell: XView {
    var body: some XView { Color(.black).frame(width: 20, height: 20) }
}

@Stateful
private struct StatefulCell: XView {
    // Unread in `body` on purpose — `_installState` runs regardless of
    // whether `body` touches the property, so this alone is enough to
    // measure the real per-node `_install` (dictionary lookup) cost.
    @XState private var painted: Bool = false

    var body: some XView { Color(.black).frame(width: 20, height: 20) }
}

private struct PlainGrid: XView {
    var body: some XView {
        VStack {
            ForEach(0..<8) { _ in
                HStack {
                    ForEach(0..<10) { _ in
                        PlainCell()
                    }
                }
            }
        }
    }
}

private struct StatefulGrid: XView {
    var body: some XView {
        VStack {
            ForEach(0..<8) { _ in
                HStack {
                    ForEach(0..<10) { _ in
                        StatefulCell()
                    }
                }
            }
        }
    }
}

// MARK: - 0. as? against a marker protocol alone, success vs. failure

// `lower(_:)` tries `as? any IntrinsicView`, then `as? _PrimitiveXView`
// (internal, can't reach from here), then `as? any _Stateful` — every
// ordinary composite (neither primitive nor stateful) fails all of them
// before falling through to `.body`. This isolates that per-attempt cost.
let plainAsAnyXView: any XView = PlainCell()
let statefulAsAnyXView: any XView = StatefulCell()

report("as? any IntrinsicView — failing (plain composite)", iterations: 1_000_000) {
    _ = plainAsAnyXView as? any IntrinsicView
}

report("as? any _Stateful — failing (plain composite)", iterations: 1_000_000) {
    _ = plainAsAnyXView as? any _Stateful
}

report("as? any _Stateful — succeeding (@Stateful composite)", iterations: 1_000_000) {
    _ = statefulAsAnyXView as? any _Stateful
}

// MARK: - 1. _installState/_install alone (dictionary lookup + cast)

private var probe = StatefulCell()
let installStore = StateStore()
report("_installState (one @XState property)", iterations: 1_000_000) {
    probe._installState(id: .root, store: installStore)
}

// MARK: - 2. StateIdentity.child(type:index:) combine alone

report("StateIdentity.child combine", iterations: 1_000_000) {
    _ = StateIdentity.root.child(type: PlainCell.self, index: 7)
}

// MARK: - 3+4. whole-tree lower() via LayoutHost.render, 80-leaf grid

let canvas = NullCanvas()
let host = LayoutHost(canvas: Size(width: 1920, height: 1080))
let renderStore = StateStore()

report("render(): 80-leaf grid, no _Stateful nodes", iterations: 10_000) {
    host.render(PlainGrid(), into: canvas, store: renderStore)
}

report("render(): 80-leaf grid, every composite is _Stateful (@XState)", iterations: 10_000) {
    host.render(StatefulGrid(), into: canvas, store: renderStore)
}
