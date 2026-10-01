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

/// The minimal state machine for one active tap/drag sequence.
///
/// This intentionally handles one pointer at a time. Pointer capture begins
/// when a pointer-down hits a tap or drag region and remains with that
/// sequence until ended or cancelled. Tap and drag compete for the same
/// sequence: a recognized drag suppresses the tap.
public struct GestureRuntime: Sendable {
    private struct ActiveSequence: @unchecked Sendable {
        let pointerID: Int
        let startLocation: Point
        let tap: ResolvedTapGesture?
        let drag: ResolvedDragGesture?
        var tapEligible: Bool
        var dragStarted: Bool
    }

    private let tapSlop: Double
    private var activeSequence: ActiveSequence?

    public init(tapSlop: Double = 10) {
        self.tapSlop = max(0, tapSlop)
    }

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
            guard activeSequence == nil else { return false }
            let tap = render.tapGestures.first(where: { $0.rect.contains(input.position) })
            let drag = render.dragGestures.first(where: { $0.rect.contains(input.position) })
            guard tap != nil || drag != nil else {
                return false
            }
            activeSequence = ActiveSequence(
                pointerID: input.id,
                startLocation: input.position,
                tap: tap,
                drag: drag,
                tapEligible: true,
                dragStarted: drag?.minimumDistance == 0
            )
            return true

        case .moved:
            guard var active = activeSequence, active.pointerID == input.id else {
                return false
            }

            let distance = distance(from: active.startLocation, to: input.position)
            if distance > tapSlop {
                active.tapEligible = false
            }
            if let drag = active.drag, !active.dragStarted, distance >= drag.minimumDistance {
                active.dragStarted = true
            }
            activeSequence = active
            if active.dragStarted, let drag = active.drag {
                drag.performChanged(
                    makeValue(input: input, startLocation: active.startLocation)
                )
            }
            return true

        case .ended:
            guard let active = activeSequence, active.pointerID == input.id else {
                return false
            }
            defer { activeSequence = nil }
            let value = makeValue(input: input, startLocation: active.startLocation)
            if active.dragStarted, let drag = active.drag {
                drag.performEnded(value)
            } else if active.tapEligible, let tap = active.tap {
                tap.perform()
            }
            return true

        case .cancelled:
            guard let active = activeSequence, active.pointerID == input.id else {
                return false
            }
            activeSequence = nil
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
