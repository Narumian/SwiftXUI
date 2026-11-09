import Foundation

/// A value that can be dragged and dropped. Inside the app the value travels as it is
/// (no serialisation); representations for other apps are added where a platform shell
/// bridges to the system.
public protocol XTransferable: Sendable {}

extension String: XTransferable {}
extension URL: XTransferable {}
extension Data: XTransferable {}
extension Int: XTransferable {}
extension UUID: XTransferable {}

/// A dragged value with its type remembered, so a drop target can ask "is this mine?" cheaply.
public struct DragPayload: @unchecked Sendable {
    public let typeID: ObjectIdentifier
    private let storage: any Sendable

    public init<T: XTransferable>(_ value: T) {
        typeID = ObjectIdentifier(T.self)
        storage = value
    }

    public func value<T: XTransferable>(as type: T.Type = T.self) -> T? { storage as? T }
}

/// What a drop does with what was dragged: the badge shown on the preview.
public enum DropOperation: Sendable, Equatable {
    case move, copy
}

/// What it takes to lift something.
public enum DragActivation: Sendable, Equatable {
    /// The store's default (`DragDropStore.automaticActivation`): a short hold on touch,
    /// a small movement where the host has a precise pointer.
    case automatic
    /// Press and hold still for this many seconds. Moving first leaves the press to
    /// whatever scrolls underneath, as on iOS.
    case hold(Double)
    /// Lift as soon as the pointer has moved this far (canvas units).
    case movement(Double)
}

/// One entry of a context menu.
public struct ContextMenuItem: Sendable, Identifiable {
    public enum Role: Sendable, Equatable { case normal, destructive }

    public let id: Int
    public let title: String
    public let role: Role
    let action: @Sendable () -> Void

    public init(_ title: String, role: Role = .normal, id: Int = 0, action: @escaping @Sendable () -> Void) {
        self.id = id
        self.title = title
        self.role = role
        self.action = action
    }

    func numbered(_ id: Int) -> ContextMenuItem { ContextMenuItem(title, role: role, id: id, action: action) }
}

/// What `.draggable` registers for a view.
struct DragSourceSpec: @unchecked Sendable {
    let id: AnyHashable
    let typeID: ObjectIdentifier
    let makePayload: @Sendable () -> DragPayload
    let preview: AnyView
    let activation: DragActivation
    let cornerRadius: Double
}

/// What `.dropDestination` registers for a view.
struct DropTargetSpec: @unchecked Sendable {
    let id: StateIdentity
    let typeID: ObjectIdentifier
    let validate: @Sendable (DragPayload) -> Bool
    let perform: @Sendable (DragPayload, Point) -> Bool
    let targeted: @Sendable (Bool) -> Void
    let springLoad: (delay: Double, action: @Sendable () -> Void)?
}

/// What `.contextMenu` registers for a view.
struct ContextMenuSpec: @unchecked Sendable {
    let items: @Sendable () -> [ContextMenuItem]
}

public struct ResolvedDragSource: @unchecked Sendable {
    public let rect: Rect
    let spec: DragSourceSpec
}

public struct ResolvedDropTarget: @unchecked Sendable {
    public let rect: Rect
    let spec: DropTargetSpec
}

public struct ResolvedContextMenu: @unchecked Sendable {
    public let rect: Rect
    let spec: ContextMenuSpec
}
