import Foundation

/// The normalized pointer phases consumed by XUI gesture recognizers.
public enum PointerInputPhase: Sendable, Equatable {
    case began
    case moved
    case ended
    case cancelled
}

/// A platform-neutral pointer sample.
///
/// Platform adapters translate mouse, touch, and pen events into this type
/// before handing them to `GestureRuntime`.
public struct PointerInput: Sendable, Equatable {
    public let id: Int
    public let phase: PointerInputPhase
    public let position: Point
    public let timestamp: Double

    public init(
        id: Int = 0,
        phase: PointerInputPhase,
        position: Point,
        timestamp: Double = 0
    ) {
        self.id = id
        self.phase = phase
        self.position = position
        self.timestamp = timestamp
    }
}

/// The value emitted by `DragGesture` callbacks.
public struct DragGestureValue: Sendable, Equatable {
    public let time: Double
    public let location: Point
    public let startLocation: Point
    public let translation: Point

    public init(
        time: Double,
        location: Point,
        startLocation: Point,
        translation: Point
    ) {
        self.time = time
        self.location = location
        self.startLocation = startLocation
        self.translation = translation
    }
}

/// A value-style one-pointer drag gesture.
///
/// Recognition begins after `minimumDistance`. The gesture does not expose
/// platform input or pointer capture; those concerns stay in
/// `GestureRuntime`.
public struct DragGesture: Gesture, Sendable {
    public typealias Value = DragGestureValue

    public let minimumDistance: Double

    private let changedAction: (@Sendable (DragGestureValue) -> Void)?
    private let endedAction: (@Sendable (DragGestureValue) -> Void)?

    public init(minimumDistance: Double = 10) {
        self.minimumDistance = max(0, minimumDistance)
        changedAction = nil
        endedAction = nil
    }

    private init(
        minimumDistance: Double,
        changedAction: (@Sendable (DragGestureValue) -> Void)?,
        endedAction: (@Sendable (DragGestureValue) -> Void)?
    ) {
        self.minimumDistance = minimumDistance
        self.changedAction = changedAction
        self.endedAction = endedAction
    }

    public func onChanged(
        _ action: @escaping @Sendable (DragGestureValue) -> Void
    ) -> Self {
        Self(
            minimumDistance: minimumDistance,
            changedAction: action,
            endedAction: endedAction
        )
    }

    public func onEnded(
        _ action: @escaping @Sendable (DragGestureValue) -> Void
    ) -> Self {
        Self(
            minimumDistance: minimumDistance,
            changedAction: changedAction,
            endedAction: action
        )
    }

    var _changedAction: (@Sendable (DragGestureValue) -> Void)? {
        changedAction
    }

    var _endedAction: (@Sendable (DragGestureValue) -> Void)? {
        endedAction
    }
}
