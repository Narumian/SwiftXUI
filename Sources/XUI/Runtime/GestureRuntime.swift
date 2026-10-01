import Foundation

/// A resolved drag target after layout.
public struct ResolvedDragGesture: @unchecked Sendable {
    public let rect: Rect
    public let minimumDistance: Double

    private let changedAction: (@Sendable (DragGestureValue) -> Void)?
    private let endedAction: (@Sendable (DragGestureValue) -> Void)?

    init(rect: Rect, gesture: DragGesture) {
        self.rect = rect
        self.minimumDistance = gesture.minimumDistance
        self.changedAction = gesture._changedAction
        self.endedAction = gesture._endedAction
    }

    func performChanged(_ value: DragGestureValue) {
        changedAction?(value)
    }

    func performEnded(_ value: DragGestureValue) {
        endedAction?(value)
    }
}

/// The minimal state machine for one active drag sequence.
///
/// This intentionally handles one pointer at a time. Pointer capture begins
/// when a pointer-down hits a drag region and remains with that region until
/// ended or cancelled.
public struct GestureRuntime: Sendable {
    private struct ActiveDrag: @unchecked Sendable {
        let pointerID: Int
        let gesture: ResolvedDragGesture
        let startLocation: Point
        var hasExceededMinimumDistance: Bool
    }

    private var activeDrag: ActiveDrag?

    public init() {}

    /// Feeds one normalized pointer sample to the drag recognizer.
    /// Returns `true` when the sample belongs to an active or newly captured
    /// drag region.
    @discardableResult
    public mutating func handle(
        _ input: PointerInput,
        in render: RenderResult
    ) -> Bool {
        switch input.phase {
        case .began:
            guard activeDrag == nil else { return false }
            guard let gesture = render.dragGestures.first(where: { $0.rect.contains(input.position) }) else {
                return false
            }
            activeDrag = ActiveDrag(
                pointerID: input.id,
                gesture: gesture,
                startLocation: input.position,
                hasExceededMinimumDistance: gesture.minimumDistance == 0
            )
            return true

        case .moved:
            guard var active = activeDrag, active.pointerID == input.id else {
                return false
            }

            let value = makeValue(
                input: input,
                startLocation: active.startLocation
            )
            if !active.hasExceededMinimumDistance {
                guard distance(from: active.startLocation, to: input.position) >= active.gesture.minimumDistance else {
                    return true
                }
                active.hasExceededMinimumDistance = true
                activeDrag = active
            }
            active.gesture.performChanged(value)
            return true

        case .ended:
            guard let active = activeDrag, active.pointerID == input.id else {
                return false
            }
            defer { activeDrag = nil }
            guard active.hasExceededMinimumDistance else { return true }
            active.gesture.performEnded(
                makeValue(input: input, startLocation: active.startLocation)
            )
            return true

        case .cancelled:
            guard let active = activeDrag, active.pointerID == input.id else {
                return false
            }
            activeDrag = nil
            return true
        }
    }

    private func makeValue(
        input: PointerInput,
        startLocation: Point
    ) -> DragGestureValue {
        DragGestureValue(
            time: input.timestamp,
            location: input.position,
            startLocation: startLocation,
            translation: Point(
                x: input.position.x - startLocation.x,
                y: input.position.y - startLocation.y
            )
        )
    }

    private func distance(from start: Point, to end: Point) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
