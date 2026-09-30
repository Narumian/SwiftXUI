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
    ) -> CompiledFrame
}

/// Lifecycle callbacks for the platform shell that hosts an XApp.
@XUIActor
public protocol XAppDelegate: AnyObject {
    func applicationDidLaunch(_ application: any XApplicationRuntimeProtocol)
    func applicationDidBecomeActive(_ application: any XApplicationRuntimeProtocol)
    func applicationWillResignActive(_ application: any XApplicationRuntimeProtocol)
    func applicationDidEnterBackground(_ application: any XApplicationRuntimeProtocol)
    func applicationWillTerminate(_ application: any XApplicationRuntimeProtocol)
}

@XUIActor
public extension XAppDelegate {
    func applicationDidLaunch(_ application: any XApplicationRuntimeProtocol) {}
    func applicationDidBecomeActive(_ application: any XApplicationRuntimeProtocol) {}
    func applicationWillResignActive(_ application: any XApplicationRuntimeProtocol) {}
    func applicationDidEnterBackground(_ application: any XApplicationRuntimeProtocol) {}
    func applicationWillTerminate(_ application: any XApplicationRuntimeProtocol) {}
}

/// Owns an app driver and translates platform lifecycle events into
/// renderer-neutral XUI callbacks.
@XUIActor
public final class XApplicationRuntime<App: XApp>: XApplicationRuntimeProtocol {
    public let driver: XAppDriver<App>
    public let delegate: (any XAppDelegate)?

    public private(set) var isRunning = false
    public private(set) var isActive = false
    public private(set) var isInBackground = false

    private var hasLaunched = false

    public init(
        _ app: App,
        renderer: any XRenderer,
        context: XApplicationContext? = nil,
        delegate: (any XAppDelegate)? = nil
    ) {
        self.driver = XAppDriver(app, renderer: renderer, context: context)
        self.delegate = delegate
    }

    /// Starts the runtime and makes it active. Platform shells can use the
    /// more granular lifecycle methods when their OS has separate callbacks.
    public func start() {
        becomeActive()
    }

    public func launch() {
        guard !hasLaunched else { return }
        hasLaunched = true
        isRunning = true
        delegate?.applicationDidLaunch(self)
    }

    public func becomeActive() {
        launch()
        guard !isActive else { return }
        isActive = true
        isInBackground = false
        delegate?.applicationDidBecomeActive(self)
    }

    public func resignActive() {
        guard isActive else { return }
        isActive = false
        delegate?.applicationWillResignActive(self)
    }

    public func enterBackground() {
        guard !isInBackground else { return }
        resignActive()
        isInBackground = true
        delegate?.applicationDidEnterBackground(self)
    }

    public func terminate() {
        guard isRunning else { return }
        resignActive()
        delegate?.applicationWillTerminate(self)
        isRunning = false
    }

    @discardableResult
    public func frame(
        at time: Double,
        framebuffer: RenderSize? = nil,
        fit: Bool = true
    ) -> CompiledFrame {
        driver.frame(at: time, framebuffer: framebuffer, fit: fit)
    }
}
