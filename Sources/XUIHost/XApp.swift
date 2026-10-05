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
@XUIActor
public protocol XApp {
    associatedtype Body: XView
    associatedtype Delegate: XAppDelegate

    @XViewBuilder
    var body: Body { get }

    var delegate: Delegate { get }
    var configuration: XAppConfiguration { get }
}

@XUIActor
public extension XApp {
    var configuration: XAppConfiguration { XAppConfiguration() }
}

/// A live application session. It owns one XUIHost so declarative state stays
/// alive across frame renders instead of being recreated with every call.
@XUIActor
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
    public func render(time: Double? = nil) async -> XUIFrame {
        await host.render(app.body, time: time)
    }
}

/// Drives an `XApp` through declaration, scene compilation, and the renderer
/// boundary for one display frame.
///
/// A platform shell owns the actual display link or event loop and calls
/// `frame(at:)`. This keeps platform lifecycle code outside the declarative
/// XUI package while giving it one stable entry point.
@XUIActor
public final class XAppDriver<App: XApp> {
    public let session: XAppSession<App>
    public let renderer: any XRenderer

    public init(_ app: App, renderer: any XRenderer) {
        self.session = XAppSession(app)
        self.renderer = renderer
    }

    private var epoch: Double?

    @discardableResult
    public func frame(
        at time: Double,
        framebuffer: RenderSize? = nil,
        fit: Bool = true
    ) async -> CompiledFrame {
        let xFrame = await session.render(time: time)
        let logicalSize = session.host.size
        let framebufferSize = framebuffer ?? logicalSize
        let compiled = SceneCompiler.compile(
            xFrame.scene,
            canvas: logicalSize,
            framebuffer: framebufferSize,
            fit: fit,
            fonts: session.host.fonts
        )
        let start = epoch ?? time
        epoch = start
        renderer.render(compiled, time: Float(time - start))
        return compiled
    }
}

/// Creates a persistent session for a declarative XApp.
@XUIActor
public enum XApplication {
    public static func session<App: XApp>(_ app: App) -> XAppSession<App> {
        XAppSession(app)
    }

    public static func runtime<App: XApp>(
        _ app: App,
        renderer: any XRenderer,
        framebuffer: RenderSize? = nil,
        fit: Bool = true
    ) -> XApplicationRuntime<App> {
        XApplicationRuntime(
            app,
            renderer: renderer,
            framebuffer: framebuffer,
            fit: fit
        )
    }
}
