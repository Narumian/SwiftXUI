import Foundation

/// The render entry point. Give it a canvas size and an environment, hand it a
/// root view and a concrete `XCanvas`, get back the layout-derived metadata.
///
/// ```swift
/// let host = LayoutHost(canvas: Size(width: 1920, height: 1080), environment: env)
/// let result = await host.render(BattleView(snapshot: s), into: sceneCanvas)
/// // result.anchors["screen"], result.regions
/// ```
public struct LayoutHost {
    public var canvas: Size
    public var environment: EnvironmentValues

    public init(canvas: Size, environment: EnvironmentValues = EnvironmentValues()) {
        self.canvas = canvas
        self.environment = environment
    }

    @discardableResult
    @XUIActor
    public func render(_ view: some XView, into surface: any XCanvas, store: StateStore = StateStore()) async -> RenderResult {
        store.beginPass(now: environment.fxTime)
        defer { store.endPass() }

        return await _XUIBindingContext.$store.withValue(store) {
            var env = environment
            env.measureText = { surface.measureText($0, fontSize: $1, font: $2) }
            var layoutContext = LayoutContext(environment: env, referenceSize: canvas)
            layoutContext.pass = LayoutPass.next()

            let root = LayoutNode(layout: RootLayout(), children: await lower(view, id: .root, store: store))
            await LayoutEngine.place(root, in: Rect(origin: .zero, size: canvas), layoutContext)

            let renderContext = RenderContext(canvas: surface, environment: env)
            LayoutEngine.render(root, into: renderContext)
            if let sink = surface as? ShaderSink {
                sink.submit(shaders: renderContext.shaders)
            }

            return RenderResult(
                regions: renderContext.regions,
                shaders: renderContext.shaders,
                controls: renderContext.controls,
                tapGestures: renderContext.tapGestures,
                anchors: renderContext.anchors
            )
        }
    }

    /// Layout only — no painting. Useful for parity tests that just want the
    /// resolved anchor rects. Text falls back to the environment's default
    /// measurer unless one was set on `environment`.
    @XUIActor
    public func resolveAnchors(_ view: some XView, store: StateStore = StateStore()) async -> [AnchorID: Rect] {
        store.beginPass(now: environment.fxTime)
        defer { store.endPass() }

        return await _XUIBindingContext.$store.withValue(store) {
            var layoutContext = LayoutContext(environment: environment, referenceSize: canvas)
            layoutContext.pass = LayoutPass.next()
            let root = LayoutNode(layout: RootLayout(), children: await lower(view, id: .root, store: store))
            await LayoutEngine.place(root, in: Rect(origin: .zero, size: canvas), layoutContext)
            var anchors: [AnchorID: Rect] = [:]
            collectAnchors(root, into: &anchors)
            return anchors
        }
    }

    private func collectAnchors(_ node: LayoutNode, into anchors: inout [AnchorID: Rect]) {
        if let id = node.anchor { anchors[id] = node.frame }
        for child in node.children { collectAnchors(child, into: &anchors) }
    }
}
