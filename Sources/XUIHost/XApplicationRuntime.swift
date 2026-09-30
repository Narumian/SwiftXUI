import XRender
import XUI

/// The platform-neutral lifecycle surface exposed to an XApp delegate.
@XUIActor
public protocol XApplicationRuntimeProtocol: AnyObject {
    var isRunning: Bool { get }
    var isActive: Bool { get }
    var isInBackground: Bool { get }

    @discardableResult
    func frame(
        at time: Double,
        framebuffer: RenderSize?,
        fit: Bool
    ) async -> CompiledFrame
}

/// Lifecycle callbacks for the platform shell that hosts an XApp.
public protocol XAppDelegate: AnyObject, Sendable {
    func applicationDidLaunch()
    func applicationDidBecomeActive()
    func applicationWillResignActive()
    func applicationDidEnterBackground()
    func applicationWillTerminate()
}

public extension XAppDelegate {
    func applicationDidLaunch() {}
    func applicationDidBecomeActive() {}
    func applicationWillResignActive() {}
    func applicationDidEnterBackground() {}
    func applicationWillTerminate() {}
}

/// Owns an app driver and translates platform lifecycle events into
/// renderer-neutral XUI callbacks.
@XUIActor
public final class XApplicationRuntime<App: XApp>: XApplicationRuntimeProtocol {
    public let app: App
    public let driver: XAppDriver<App>
    private let loop: XAsyncLoop<App>

    public private(set) var isRunning = false
    public private(set) var isActive = false
    public private(set) var isInBackground = false

    private var hasLaunched = false

    public init(
        _ app: App,
        renderer: any XRenderer,
        maxFPS: Double = 60,
        framebuffer: RenderSize? = nil,
        fit: Bool = true
    ) {
        self.app = app
        self.driver = XAppDriver(app, renderer: renderer)
        self.loop = XAsyncLoop(driver: driver, maxFPS: maxFPS, framebuffer: framebuffer, fit: fit)
    }

    /// Starts the runtime and makes it active. Platform shells can use the
    /// more granular lifecycle methods when their OS has separate callbacks.
    public func start() {
        becomeActive()
        loop.start()
    }

    public func launch() {
        guard !hasLaunched else { return }
        hasLaunched = true
        isRunning = true
        app.delegate.applicationDidLaunch()
    }

    public func becomeActive() {
        launch()
        guard !isActive else { return }
        isActive = true
        isInBackground = false
        app.delegate.applicationDidBecomeActive()
    }

    public func resignActive() {
        guard isActive else { return }
        isActive = false
        app.delegate.applicationWillResignActive()
    }

    public func enterBackground() {
        guard !isInBackground else { return }
        resignActive()
        isInBackground = true
        app.delegate.applicationDidEnterBackground()
    }

    public func terminate() {
        guard isRunning else { return }
        loop.stop()
        resignActive()
        app.delegate.applicationWillTerminate()
        isRunning = false
    }

    /// Requests one coalesced frame. The loop remains asleep until this is
    /// called again when no animation or other work is active.
    public func setNeedsDisplay() {
        loop.setNeedsDisplay()
    }

    @discardableResult
    public func frame(
        at time: Double,
        framebuffer: RenderSize? = nil,
        fit: Bool = true
    ) async -> CompiledFrame {
        await driver.frame(at: time, framebuffer: framebuffer, fit: fit)
    }
}
