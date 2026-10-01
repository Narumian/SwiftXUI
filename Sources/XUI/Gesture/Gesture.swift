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
