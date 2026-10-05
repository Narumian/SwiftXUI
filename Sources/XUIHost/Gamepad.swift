import Foundation
import XUI

#if canImport(GameController)
import GameController
#endif

public enum GamepadDirection: Sendable, Equatable {
    case up
    case down
    case left
    case right
}

/// Platform-neutral input events understood by XUI's focus router.
public enum GamepadInput: Sendable, Equatable {
    case direction(GamepadDirection)
    case confirm
    case back
}

/// Converts directional controls from Apple's GameController framework into
/// platform-neutral XUI events. The app shell forwards those events to
/// `XUIHost.gamepad(_:in:)`.
public final class GamepadInputSource: @unchecked Sendable {
    public var onInput: (@Sendable (GamepadInput) -> Void)?
    public var deadZone: Float

    #if canImport(GameController)
    private var observers: [NSObjectProtocol] = []
    private var activeDirection: GamepadDirection?
    #endif

    public init(deadZone: Float = 0.55) {
        self.deadZone = min(max(deadZone, 0), 1)
    }

    #if canImport(GameController)
    public func start() {
        stop()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSNotification.Name.GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            self?.configure(controller)
        })
        observers.append(center.addObserver(
            forName: NSNotification.Name.GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.activeDirection = nil
        })

        GCController.controllers().forEach(configure)
        GCController.startWirelessControllerDiscovery {}
    }

    public func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        GCController.stopWirelessControllerDiscovery()
        activeDirection = nil
    }

    private func configure(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }

        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.onInput?(.confirm)
        }
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.onInput?(.back)
        }

        let directionChanged: (Float, Float) -> Void = { [weak self] x, y in
            self?.emitDirection(x: x, y: y)
        }
        pad.dpad.valueChangedHandler = { _, x, y in directionChanged(x, y) }
        pad.leftThumbstick.valueChangedHandler = { _, x, y in directionChanged(x, y) }
    }

    private func emitDirection(x: Float, y: Float) {
        guard max(abs(x), abs(y)) >= deadZone else {
            activeDirection = nil
            return
        }

        let direction: GamepadDirection
        if abs(y) >= abs(x) {
            direction = y > 0 ? .down : .up
        } else {
            direction = x > 0 ? .right : .left
        }
        guard direction != activeDirection else { return }
        activeDirection = direction
        onInput?(.direction(direction))
    }
    #else
    public func start() {}
    public func stop() {}
    #endif
}

struct FocusNavigator {
    static func selectInitial(in controls: [ResolvedControl], current: ControlID?) -> ControlID? {
        if let current, controls.contains(where: { $0.control.id == current }) {
            return current
        }
        return controls.first?.control.id
    }

    static func next(
        from currentID: ControlID?,
        direction: GamepadDirection,
        controls: [ResolvedControl]
    ) -> ControlID? {
        guard !controls.isEmpty else { return nil }
        guard
            let currentID,
            let current = controls.first(where: { $0.control.id == currentID })
        else { return controls.first?.control.id }

        let origin = Point(x: current.rect.midX, y: current.rect.midY)
        let candidates = controls.filter { candidate in
            guard candidate.control.scope == current.control.scope,
                  candidate.control.id != current.control.id else { return false }
            let center = Point(x: candidate.rect.midX, y: candidate.rect.midY)
            switch direction {
            case .up: return center.y < origin.y - 1
            case .down: return center.y > origin.y + 1
            case .left: return center.x < origin.x - 1
            case .right: return center.x > origin.x + 1
            }
        }

        return candidates.min { lhs, rhs in
            score(lhs.rect, from: origin, direction: direction)
                < score(rhs.rect, from: origin, direction: direction)
        }?.control.id ?? current.control.id
    }

    private static func score(_ rect: Rect, from origin: Point, direction: GamepadDirection) -> Double {
        let center = Point(x: rect.midX, y: rect.midY)
        let primary: Double
        let secondary: Double
        switch direction {
        case .up, .down:
            primary = abs(center.y - origin.y)
            secondary = abs(center.x - origin.x)
        case .left, .right:
            primary = abs(center.x - origin.x)
            secondary = abs(center.y - origin.y)
        }
        return primary * 1000 + secondary
    }
}
