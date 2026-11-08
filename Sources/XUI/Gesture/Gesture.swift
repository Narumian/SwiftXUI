import Foundation

/// A declarative interaction that can be attached to an `XView`.
///
/// The protocol intentionally starts as a small public marker. Concrete
/// gestures expose their value and callbacks, while recognition and input
/// routing remain an implementation detail of XUI.
public protocol Gesture: Sendable {
    associatedtype Value: Sendable
}

/// A gesture that recognizes a completed tap.
///
/// `TapGesture` is the value-type spelling of the existing tap interaction.
/// The closure is stored on the gesture and is installed into the existing
/// resolved tap pipeline by `XView.gesture(_:)`.
public struct TapGesture: Gesture, Sendable {
    public typealias Value = Void

    private let endedAction: (@Sendable () -> Void)?

    public init() {
        endedAction = nil
    }

    private init(endedAction: (@Sendable () -> Void)?) {
        self.endedAction = endedAction
    }

    /// Returns a copy that invokes `action` when the tap completes.
    public func onEnded(_ action: @escaping @Sendable () -> Void) -> Self {
        Self(endedAction: action)
    }

    var _endedAction: (@Sendable () -> Void)? {
        endedAction
    }
}

/// A gesture that recognizes a press held in place for `minimumDuration` seconds.
///
/// Recognition happens when the pointer is lifted, not while it is held: the runtime has no
/// timer, so it measures the time between pointer-down and pointer-up from the samples'
/// `timestamp` (seconds). A hold that moves further than the tap slop is not a long press.
/// A view with a long press and a tap performs only the long press after a long hold, and
/// only the tap after a short one. A host that sends no timestamps (every sample 0) never
/// produces a long press.
public struct LongPressGesture: Gesture, Sendable {
    public typealias Value = Void

    public let minimumDuration: Double
    private let endedAction: (@Sendable () -> Void)?

    public init(minimumDuration: Double = 0.5) {
        self.minimumDuration = minimumDuration.isFinite ? max(0, minimumDuration) : 0.5
        endedAction = nil
    }

    private init(minimumDuration: Double, endedAction: (@Sendable () -> Void)?) {
        self.minimumDuration = minimumDuration
        self.endedAction = endedAction
    }

    /// Returns a copy that invokes `action` when a long press completes.
    public func onEnded(_ action: @escaping @Sendable () -> Void) -> Self {
        Self(minimumDuration: minimumDuration, endedAction: action)
    }

    var _endedAction: (@Sendable () -> Void)? { endedAction }
}
