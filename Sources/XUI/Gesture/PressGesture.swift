import Foundation

/// A gesture that reports the pointer going down and coming up, for controls that act while held:
/// a pad that plays while it is pressed, a momentary switch, a key.
///
/// Unlike `TapGesture` it fires at pointer-down, and it runs alongside the other gestures of the
/// view instead of competing with them: a view can have a press and a tap, and a drag that starts
/// on it does not end the press. The press ends only when the pointer is lifted (`onReleased`) or the
/// sequence is cancelled (`onCancelled`: the system took the touch, a lifted drag-and-drop took the
/// pointer, the app lost focus). Moving out of the view does not release it. Every `onPressed` is
/// followed by exactly one of `onReleased` or `onCancelled`, so a control that starts something on
/// press can always stop it.
///
/// The runtime follows one pointer at a time, so a second finger is ignored while one is held.
public struct PressGesture: Gesture, Sendable {
    public typealias Value = Void

    private let pressedAction: (@Sendable () -> Void)?
    private let releasedAction: (@Sendable () -> Void)?
    private let cancelledAction: (@Sendable () -> Void)?

    public init() {
        pressedAction = nil; releasedAction = nil; cancelledAction = nil
    }

    private init(pressed: (@Sendable () -> Void)?, released: (@Sendable () -> Void)?, cancelled: (@Sendable () -> Void)?) {
        pressedAction = pressed; releasedAction = released; cancelledAction = cancelled
    }

    /// Returns a copy that invokes `action` when the pointer goes down on the view.
    public func onPressed(_ action: @escaping @Sendable () -> Void) -> Self {
        Self(pressed: action, released: releasedAction, cancelled: cancelledAction)
    }

    /// Returns a copy that invokes `action` when the pointer that pressed is lifted.
    public func onReleased(_ action: @escaping @Sendable () -> Void) -> Self {
        Self(pressed: pressedAction, released: action, cancelled: cancelledAction)
    }

    /// Returns a copy that invokes `action` when the press ends without a lift.
    public func onCancelled(_ action: @escaping @Sendable () -> Void) -> Self {
        Self(pressed: pressedAction, released: releasedAction, cancelled: action)
    }

    var _pressedAction: (@Sendable () -> Void)? { pressedAction }
    var _releasedAction: (@Sendable () -> Void)? { releasedAction }
    var _cancelledAction: (@Sendable () -> Void)? { cancelledAction }
}

/// A resolved press target after layout.
public struct ResolvedPressGesture: @unchecked Sendable {
    public let rect: Rect
    private let pressed: (@Sendable () -> Void)?
    private let released: (@Sendable () -> Void)?
    private let cancelled: (@Sendable () -> Void)?

    init(rect: Rect, gesture: PressGesture) {
        self.rect = rect
        pressed = gesture._pressedAction
        released = gesture._releasedAction
        cancelled = gesture._cancelledAction
    }

    public func performPressed() { pressed?() }
    public func performReleased() { released?() }
    public func performCancelled() { cancelled?() }
}
