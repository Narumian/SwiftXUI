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
    /// Change this when canvas measurement metrics change. With `nil`, retained
    /// subtrees are laid out every pass because their metrics cannot be compared.
    public var measurementRevision: UInt64?

    public init(canvas: Size, environment: EnvironmentValues = EnvironmentValues(), measurementRevision: UInt64? = nil) {
        self.canvas = canvas
        self.environment = environment
        self.measurementRevision = measurementRevision
    }

    /// Returns a host with an exact-type environment object injected.
    /// Convenient when constructing a host inline:
    /// `LayoutHost(canvas: size).environmentObject(model)`.
    public func environmentObject<Object: AnyObject>(_ object: Object) -> LayoutHost {
        var copy = self
        copy.environment.environmentObject(object)
        return copy
    }

    @discardableResult
    @XUIActor
    public func render(_ view: some XView, into surface: any XCanvas, store: StateStore = StateStore()) async -> RenderResult {
        await render(into: surface, store: store, reusing: nil) { view }.result
    }

    package struct PlacedRoot {
        fileprivate let node: LayoutNode
    }

    @XUIActor
    package func render<View: XView>(
        into surface: any XCanvas, store: StateStore, reusing placed: PlacedRoot?,
        view: @XUIActor () async -> View
    ) async -> (result: RenderResult, root: PlacedRoot) {
        XViewProfiler.beginFrame()
        let rebuild = placed == nil
        if rebuild { store.beginPass(now: environment.fxTime) }
        else { store.advanceClock(to: environment.fxTime) }
        defer { if rebuild { store.endPass() } }

        var env = environment
        env.measureText = { surface.measureText($0, fontSize: $1, font: $2) }
        return await _EnvironmentObjectContext.$current.withValue(env._environmentObjectContext()) {
            let root: LayoutNode
            if let placed {
                root = placed.node
            } else {
                var layoutContext = LayoutContext(environment: env, referenceSize: canvas, measurementRevision: measurementRevision)
                layoutContext.pass = LayoutPass.next()
                let children = await lower(view(), id: .root, store: store)
                root = LayoutNode(layout: RootLayout(), children: children)
                await LayoutEngine.place(root, in: Rect(origin: .zero, size: canvas), layoutContext)
            }

            let renderContext = RenderContext(canvas: surface, environment: env)
            LayoutEngine.render(root, into: renderContext)
            if let sink = surface as? ShaderSink {
                sink.submit(shaders: renderContext.shaders)
            }
            XViewProfiler.finishFrame()

            let result = RenderResult(
                regions: renderContext.regions,
                shaders: renderContext.shaders,
                controls: renderContext.controls,
                tapGestures: renderContext.tapGestures,
                dragGestures: renderContext.dragGestures,
                longPressGestures: renderContext.longPressGestures,
                pressGestures: renderContext.pressGestures,
                dragSources: renderContext.dragSources,
                dropTargets: renderContext.dropTargets,
                contextMenus: renderContext.contextMenus,
                shortcuts: renderContext.shortcuts,
                anchors: renderContext.anchors
            )
            return (result, PlacedRoot(node: root))
        }
    }

    /// Layout only — no painting. Useful for parity tests that just want the
    /// resolved anchor rects. Text falls back to the environment's default
    /// measurer unless one was set on `environment`.
    @XUIActor
    public func resolveAnchors(_ view: some XView, store: StateStore = StateStore()) async -> [AnchorID: Rect] {
        store.beginPass(now: environment.fxTime)
        defer { store.endPass() }

        var layoutContext = LayoutContext(environment: environment, referenceSize: canvas)
        layoutContext.pass = LayoutPass.next()
        return await _EnvironmentObjectContext.$current.withValue(environment._environmentObjectContext()) {
            let children = await lower(view, id: .root, store: store)
            let root = LayoutNode(layout: RootLayout(), children: children)
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
