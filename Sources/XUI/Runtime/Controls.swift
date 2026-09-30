import Foundation

/// Stable semantic identity for an actionable XUI view. It deliberately has no
/// connection to a device, a gesture, or an application's domain action.
public struct ControlID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(rawValue: value) }
}

/// A named group of controls that may participate in the same focus traversal.
/// Presenters activate a modal scope instead of letting its controls leak into
/// the screen underneath.
public struct FocusScopeID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(rawValue: value) }

    public static let content: Self = "content"
}

/// Semantic metadata carried by an actionable XUI view through layout.
public struct XControl: Hashable, Sendable {
    public let id: ControlID
    public let label: String
    public let scope: FocusScopeID

    public init(id: ControlID, label: String, scope: FocusScopeID = .content) {
        self.id = id
        self.label = label
        self.scope = scope
    }
}

/// An XUI control after layout has assigned it a concrete frame.
public struct ResolvedControl: Sendable {
    public let control: XControl
    public let rect: Rect

    public init(control: XControl, rect: Rect) {
        self.control = control
        self.rect = rect
    }
}
