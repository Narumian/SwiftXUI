import XUI

/// The application-wide dependency and document scope for an XApp.
///
/// This is intentionally a plain reference object rather than an Observation
/// model. XUI views read it through `EnvironmentValues`, while changes are
/// announced explicitly through the contained signals. The runtime can later
/// connect those signals to its invalidation policy.
@XUIActor
public final class XApplicationContext {
    public let document: XDocumentContext
    public let services: XAppServices

    public init(
        document: XDocumentContext = XDocumentContext(),
        services: XAppServices = XAppServices()
    ) {
        self.document = document
        self.services = services
    }
}

/// The document-scoped state shared by the views belonging to one app session.
///
/// The actual document model and file persistence will be layered on later.
/// For now this type establishes the lifetime, change channel, and revision
/// boundary that those pieces can attach to without making `StateStore` carry
/// application-wide state.
@XUIActor
public final class XDocumentContext {
    /// Emits after the document has changed and should be reconsidered by the
    /// host. Delivery is synchronous on `XUIActor`.
    public let changed = Signal<Void>()

    /// Monotonically increasing document revision for cheap snapshot checks.
    public private(set) var revision: UInt64 = 0

    public init() {}

    /// Marks the document as changed. Persistence and domain commands can use
    /// this boundary once they are introduced.
    public func markChanged() {
        revision &+= 1
        changed.send()
    }
}

/// Application-wide services owned by an `XApplicationContext`.
///
/// Kept as a value container for now so apps can grow this API deliberately;
/// platform-specific services should not be smuggled into `StateStore`.
public struct XAppServices {
    public init() {}
}

private enum ApplicationContextKey: EnvironmentKey {
    static let defaultValue: XApplicationContext? = nil
}

private enum DocumentContextKey: EnvironmentKey {
    static let defaultValue: XDocumentContext? = nil
}

public extension EnvironmentValues {
    /// The app-wide context installed by `XAppSession`.
    var applicationContext: XApplicationContext? {
        get { self[ApplicationContextKey.self] }
        set { self[ApplicationContextKey.self] = newValue }
    }

    /// The active document context installed by `XAppSession`.
    var documentContext: XDocumentContext? {
        get { self[DocumentContextKey.self] }
        set { self[DocumentContextKey.self] = newValue }
    }
}
