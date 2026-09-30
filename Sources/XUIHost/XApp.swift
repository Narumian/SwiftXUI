import XRender
import XUI

/// Configuration shared by an XApp and the host that presents it.
public struct XAppConfiguration {
    public var size: RenderSize
    public var background: RenderColor
    public var environment: EnvironmentValues

    public init(
        size: RenderSize = RenderSize(width: 1920, height: 1080),
        background: RenderColor = RenderColor(0, 0, 0, 0),
        environment: EnvironmentValues = EnvironmentValues()
    ) {
        self.size = size
        self.background = background
        self.environment = environment
    }
}

/// The declarative application root. Platform lifecycle and display-loop
/// integration are supplied by the host layer; the app only declares its root
/// XView and presentation configuration.
public protocol XApp {
    associatedtype Body: XView

    @XViewBuilder
    var body: Body { get }

    var configuration: XAppConfiguration { get }
}

public extension XApp {
    var configuration: XAppConfiguration { XAppConfiguration() }
}

/// A live application session. It owns one XUIHost so declarative state stays
/// alive across frame renders instead of being recreated with every call.
public final class XAppSession<App: XApp> {
    public let app: App
    public let host: XUIHost

    public init(_ app: App) {
        self.app = app
        let configuration = app.configuration
        self.host = XUIHost(
            size: configuration.size,
            background: configuration.background,
            environment: configuration.environment
        )
    }

    @discardableResult
    public func render(time: Double? = nil) -> XUIFrame {
        host.render(app.body, time: time)
    }
}

/// Creates a persistent session for a declarative XApp.
public enum XApplication {
    public static func session<App: XApp>(_ app: App) -> XAppSession<App> {
        XAppSession(app)
    }
}
