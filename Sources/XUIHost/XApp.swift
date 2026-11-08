import XRender
import XUI

/// Configuration shared by an XApp and the host that presents it.
public struct XAppConfiguration {
    public var size: RenderSize
    public var background: RenderColor
    public var environment: EnvironmentValues
    public var mcpEnabled: Bool

    public init(
        size: RenderSize = RenderSize(width: 1920, height: 1080),
        background: RenderColor = RenderColor(0, 0, 0, 0),
        environment: EnvironmentValues = EnvironmentValues(),
        mcpEnabled: Bool = false
    ) {
        self.size = size
        self.background = background
        self.environment = environment
        self.mcpEnabled = mcpEnabled
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
    public private(set) var lastFrame: XUIFrame?

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
        let frame = await host.render(app.body, time: time)
        lastFrame = frame
        return frame
    }

    @discardableResult
    public func pointer(_ event: PointerEvent) -> Bool {
        guard let lastFrame else { return false }
        return host.pointer(event, in: lastFrame)
    }

    /// Creates a server for this session when enabled by the app configuration.
    /// The host supplies a capture of the presented surface and redraw callback.
    public func mcpServer(port: UInt16 = 47321,
                          capture: @escaping XUIMCPServer.Capture,
                          invalidate: @escaping @Sendable () -> Void) -> XUIMCPServer? {
        guard app.configuration.mcpEnabled else { return nil }
        return XUIMCPServer(port: port,
            state: { [weak self] in
                guard let self else { throw XUIMCPError.noFrame }
                return try self.mcpState()
            }, tap: { [weak self] id in
                guard let self else { throw XUIMCPError.noFrame }
                let handled = try self.mcpTap(id: id)
                if handled { invalidate() }
                return handled
            }, pointer: { [weak self] phase, x, y in
                guard let self else { throw XUIMCPError.noFrame }
                let converted: PointerPhase
                switch phase {
                case "began": converted = .began
                case "moved": converted = .moved
                case "ended": converted = .ended
                case "cancelled": converted = .cancelled
                default: throw XUIMCPError.invalidRequest("Invalid pointer phase")
                }
                let handled = self.pointer(PointerEvent(phase: converted, position: RenderPoint(x: Float(x), y: Float(y))))
                if handled { invalidate() }
                return handled
            }, capture: capture)
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
        let t0 = FrameProbe.now
        let xFrame = await session.render(time: time)
        let t1 = FrameProbe.now
        let logicalSize = session.host.size
        let framebufferSize = framebuffer ?? logicalSize
        let compiled = SceneCompiler.compile(
            xFrame.scene,
            canvas: logicalSize,
            framebuffer: framebufferSize,
            fit: fit,
            fonts: session.host.fonts
        )
        let t2 = FrameProbe.now
        let start = epoch ?? time
        epoch = start
        renderer.render(compiled, time: Float(time - start))
        FrameProbe.record(build: t1 - t0, compile: t2 - t1, submit: FrameProbe.now - t2)
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
