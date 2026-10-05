import Foundation

/// Shared focus state between the renderer host and declarative XViews.
///
/// The host changes `selectedID` in response to keyboard/gamepad input. XUI
/// views read it while lowering to draw focus decoration and keep scroll
/// containers aligned with the selected control.
public final class FocusStore: @unchecked Sendable {
    public var selectedID: ControlID?

    private var controlRects: [ControlID: Rect] = [:]
    private var scrollViewRects: [String: Rect] = [:]

    public init(selectedID: ControlID? = nil) {
        self.selectedID = selectedID
    }

    func recordControl(_ control: XControl, rect: Rect) {
        controlRects[control.id] = rect
    }

    func recordScrollView(id: String, rect: Rect) {
        scrollViewRects[id] = rect
    }

    func controlRect(for id: ControlID) -> Rect? {
        controlRects[id]
    }

    func scrollViewRect(for id: String) -> Rect? {
        scrollViewRects[id]
    }

    /// Adjusts a scroll offset just enough to reveal the selected control.
    func offsetToRevealSelected(in scrollViewID: String, current offset: Double) -> Double {
        guard
            let selectedID,
            let control = controlRect(for: selectedID),
            let viewport = scrollViewRect(for: scrollViewID)
        else { return offset }

        let margin = 12.0
        if control.minY < viewport.minY + margin {
            return max(0, offset - (viewport.minY + margin - control.minY))
        }
        if control.maxY > viewport.maxY - margin {
            return max(0, offset + (control.maxY - (viewport.maxY - margin)))
        }
        return offset
    }
}
