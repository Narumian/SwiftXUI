import Foundation
import XRender
import XShader

/// A named-rect export. `.anchor("screen")` on a view makes its resolved frame
/// available as `result.anchors["screen"]`.
public struct AnchorID: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static func == (lhs: AnchorID, rhs: AnchorID) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}

public struct AnchorMap {
    private var storage: [String: Rect] = [:]

    public init() {}

    public subscript(_ id: AnchorID) -> Rect? {
        get { storage[id.rawValue] }
        set { storage[id.rawValue] = newValue }
    }

    public subscript(_ id: String) -> Rect? {
        get { storage[id] }
        set { storage[id] = newValue }
    }
}

/// A hit region collected during the walk: the resolved rect plus whatever
/// payload `.region(_:)` carried (the app casts it back, e.g. to `PlayerAction`).
public struct ResolvedRegion {
    public var rect: Rect
    public var payload: AnyHashable
}

/// A shader modifier paired with the frame it resolved to. The backend decides
/// whether the scope becomes a material, layer, or post pass.
public struct ResolvedShader: Sendable, Equatable {
    public var rect: Rect
    public var shader: AnyShader

    public init(rect: Rect, shader: AnyShader) {
        self.rect = rect
        self.shader = shader
    }
}

/// Optional sink implemented by a concrete canvas that can carry resolved
/// shader metadata into its renderer-neutral scene.
public protocol ShaderSink: AnyObject {
    func submit(shaders: [ResolvedShader])
}

/// Optional canvas capability for shaders whose scope is `.layer`. The layout
/// walk brackets the exact view subtree, allowing a renderer to rasterise it
/// independently instead of approximating it with a screen-space rectangle.
public protocol LayerShaderSink: AnyObject {
    func beginLayerShader(_ shader: AnyShader, in rect: Rect)
    func endLayerShader()
}

/// A resolved tap gesture collected during the walk. The action belongs to the
/// view declaration; callers decide when a pointer/touch hit should perform it.
public struct ResolvedTapGesture {
    public var rect: Rect
    public var id: String?
    public var label: String?
    private let action: () -> Void

    init(rect: Rect, id: String?, label: String?, action: @escaping () -> Void) {
        self.rect = rect
        self.id = id
        self.label = label
        self.action = action
    }

    public func perform() {
        action()
    }
}

/// Hit targets for one interactive Camera-hosted plane. Rects are in the
/// plane's local layout space (`(0,0)`…`planeSize`); picking remaps screen
/// points through `X3DPlaneHit`.
public struct ResolvedX3DPlane {
    public var hostRect: Rect
    public var planeSize: Size
    public var camera: X3DCamera
    public var model: X3DTransform
    public var regions: [ResolvedRegion]
    public var tapGestures: [ResolvedTapGesture]
    public var dragGestures: [ResolvedDragGesture]
    public var controls: [ResolvedControl]
}

/// Everything a leaf needs while painting: the canvas, the environment, and the
/// sinks for regions and anchors. Reference type — one instance per render.
public final class RenderContext {
    public let canvas: any XCanvas
    public var environment: EnvironmentValues
    public private(set) var regions: [ResolvedRegion] = []
    public private(set) var shaders: [ResolvedShader] = []
    public private(set) var controls: [ResolvedControl] = []
    public private(set) var tapGestures: [ResolvedTapGesture] = []
    public private(set) var dragGestures: [ResolvedDragGesture] = []
    public private(set) var x3dPlanes: [ResolvedX3DPlane] = []
    public private(set) var x3dDiagnostics: [X3DDiagnostic] = []
    public private(set) var anchors = AnchorMap()
    var inputSuspendedDepth = 0
    var focusScopeStack: [FocusScopeID] = []
    private var drawingOriginStack: [Point] = []
    private var suppressFocusRecording = false

    private var acceptsInput: Bool { inputSuspendedDepth == 0 }

    init(canvas: any XCanvas, environment: EnvironmentValues) {
        self.canvas = canvas
        self.environment = environment
    }

    struct PlaneInputMarker {
        let regions: Int
        let taps: Int
        let drags: Int
        let controls: Int
    }

    func beginPlaneInputCapture() -> PlaneInputMarker {
        suppressFocusRecording = true
        return PlaneInputMarker(
            regions: regions.count,
            taps: tapGestures.count,
            drags: dragGestures.count,
            controls: controls.count
        )
    }

    func endPlaneInputCapture(
        _ marker: PlaneInputMarker,
        hostRect: Rect,
        planeSize: Size,
        camera: X3DCamera,
        model: X3DTransform
    ) {
        suppressFocusRecording = false
        let plane = ResolvedX3DPlane(
            hostRect: hostRect,
            planeSize: planeSize,
            camera: camera,
            model: model,
            regions: Array(regions[marker.regions...]),
            tapGestures: Array(tapGestures[marker.taps...]),
            dragGestures: Array(dragGestures[marker.drags...]),
            controls: Array(controls[marker.controls...])
        )
        if regions.count > marker.regions { regions.removeSubrange(marker.regions...) }
        if tapGestures.count > marker.taps { tapGestures.removeSubrange(marker.taps...) }
        if dragGestures.count > marker.drags { dragGestures.removeSubrange(marker.drags...) }
        if controls.count > marker.controls { controls.removeSubrange(marker.controls...) }
        x3dPlanes.append(plane)
        promotePlaneControls(plane)
    }

    /// Projects interactive plane controls into screen-space so gamepad / focus
    /// navigation can target them with the same AABB hit path as 2D controls.
    private func promotePlaneControls(_ plane: ResolvedX3DPlane) {
        let viewSize = SIMD2(Float(plane.hostRect.width), Float(plane.hostRect.height))
        let planeSize = SIMD2(Float(plane.planeSize.width), Float(plane.planeSize.height))
        let focus = _EnvironmentObjectContext.currentOrEmpty.object(FocusStore.self)
        for control in plane.controls {
            let local = (
                min: SIMD2(Float(control.rect.minX), Float(control.rect.minY)),
                max: SIMD2(Float(control.rect.maxX), Float(control.rect.maxY))
            )
            guard let projected = X3DPlaneHit.projectRect(
                local,
                viewSize: viewSize,
                planeSize: planeSize,
                camera: plane.camera,
                model: plane.model
            ) else { continue }
            let screen = Rect(
                x: Double(projected.min.x) + plane.hostRect.x,
                y: Double(projected.min.y) + plane.hostRect.y,
                width: Double(max(0, projected.max.x - projected.min.x)),
                height: Double(max(0, projected.max.y - projected.min.y))
            )
            controls.append(ResolvedControl(control: control.control, rect: screen))
            focus?.recordControl(control.control, rect: screen)
        }
    }

    func recordDiagnostics(_ issues: [X3DDiagnostic]) {
        x3dDiagnostics.append(contentsOf: issues)
    }

    func addRegion(_ rect: Rect, payload: AnyHashable) {
        guard acceptsInput else { return }
        regions.append(ResolvedRegion(rect: rect, payload: payload))
    }

    func addShader(_ rect: Rect, shader: AnyShader) {
        shaders.append(ResolvedShader(rect: rect, shader: shader))
    }

    func addControl(_ control: XControl, rect: Rect) {
        guard acceptsInput else { return }
        let scoped = focusScopeStack.last.map { XControl(id: control.id, label: control.label, scope: $0) } ?? control
        controls.append(ResolvedControl(control: scoped, rect: rect))
        guard !suppressFocusRecording else { return }
        _EnvironmentObjectContext.currentOrEmpty
            .object(FocusStore.self)?
            .recordControl(scoped, rect: rect)
    }

    func addScrollViewport(id: String, rect: Rect) {
        _EnvironmentObjectContext.currentOrEmpty
            .object(FocusStore.self)?
            .recordScrollView(id: id, rect: rect)
    }

    func addTapGesture(_ rect: Rect, id: String?, label: String?, action: @escaping () -> Void) {
        guard acceptsInput else { return }
        tapGestures.append(ResolvedTapGesture(rect: rect, id: id, label: label, action: action))
    }

    func addDragGesture(_ rect: Rect, gesture: DragGesture) {
        guard acceptsInput else { return }
        dragGestures.append(ResolvedDragGesture(rect: rect, gesture: gesture))
    }

    func setAnchor(_ id: AnchorID, _ rect: Rect) {
        anchors[id] = rect
    }

    /// Register a hit region from inside a `DrawLayer` — for sub-areas a leaf
    /// paints itself (per-enemy hitboxes, a row of buttons drawn in one pass).
    public func hitRegion(_ rect: Rect, _ payload: some Hashable) {
        guard acceptsInput else { return }
        let origin = drawingOriginStack.last ?? .zero
        regions.append(ResolvedRegion(
            rect: rect.offsetBy(dx: origin.x, dy: origin.y),
            payload: AnyHashable(payload)
        ))
    }

    /// Runs imperative drawing code in a local coordinate system. SceneKit
    /// uses this for `SceneDraw`; the layout walk still keeps all resolved
    /// metadata in absolute canvas coordinates.
    public func withDrawingOrigin<T>(_ origin: Point, _ body: () throws -> T) rethrows -> T {
        drawingOriginStack.append(origin)
        defer { drawingOriginStack.removeLast() }
        return try body()
    }
}

/// What a render pass produces. `scene` lives on the concrete canvas; this is
/// the layout-derived metadata the app folds into its own `Output`.
public struct RenderResult {
    public var regions: [ResolvedRegion]
    public var shaders: [ResolvedShader]
    public var controls: [ResolvedControl]
    public var tapGestures: [ResolvedTapGesture]
    public var dragGestures: [ResolvedDragGesture]
    public var x3dPlanes: [ResolvedX3DPlane]
    public var x3dDiagnostics: [X3DDiagnostic]
    public var anchors: AnchorMap
    /// Epoch-relative seconds for plane orbit / `X3DPlaneHit` (usually `x3d.time`).
    public var x3dTime: Float

    public init(
        regions: [ResolvedRegion],
        shaders: [ResolvedShader] = [],
        controls: [ResolvedControl] = [],
        tapGestures: [ResolvedTapGesture] = [],
        dragGestures: [ResolvedDragGesture] = [],
        x3dPlanes: [ResolvedX3DPlane] = [],
        x3dDiagnostics: [X3DDiagnostic] = [],
        anchors: AnchorMap,
        x3dTime: Float = 0
    ) {
        self.regions = regions
        self.shaders = shaders
        self.controls = controls
        self.tapGestures = tapGestures
        self.dragGestures = dragGestures
        self.x3dPlanes = x3dPlanes
        self.x3dDiagnostics = x3dDiagnostics
        self.anchors = anchors
        self.x3dTime = x3dTime
    }

    /// First region whose payload is of type `T`, hit-tested against `point`.
    /// Flat 2D regions win; interactive X3D planes are tested afterward.
    public func hit<T>(_ point: Point, as type: T.Type = T.self) -> T? {
        for region in regions where region.rect.contains(point) {
            if let match = region.payload.base as? T { return match }
        }
        for plane in x3dPlanes.reversed() {
            guard let local = plane.localPoint(for: point, time: x3dTime) else { continue }
            for region in plane.regions where region.rect.contains(local) {
                if let match = region.payload.base as? T { return match }
            }
        }
        return nil
    }

    /// Perform the first closure tap gesture whose resolved rect contains
    /// `point`. Returns whether a gesture handled the point.
    @discardableResult
    public func tap(_ point: Point) -> Bool {
        if let gesture = tapGesture(at: point) {
            gesture.perform()
            return true
        }
        return false
    }

    public func tapGesture(at point: Point) -> ResolvedTapGesture? {
        if let gesture = tapGestures.first(where: { $0.rect.contains(point) }) {
            return gesture
        }
        for plane in x3dPlanes.reversed() {
            guard let local = plane.localPoint(for: point, time: x3dTime) else { continue }
            if let gesture = plane.tapGestures.first(where: { $0.rect.contains(local) }) {
                return gesture
            }
        }
        return nil
    }

    public func dragGesture(at point: Point) -> ResolvedDragGesture? {
        if let gesture = dragGestures.first(where: { $0.rect.contains(point) }) {
            return gesture
        }
        for plane in x3dPlanes.reversed() {
            guard let local = plane.localPoint(for: point, time: x3dTime) else { continue }
            if let gesture = plane.dragGestures.first(where: { $0.rect.contains(local) }) {
                return gesture
            }
        }
        return nil
    }
}

public extension ResolvedX3DPlane {
    /// Screen point → plane-local layout point when the ray hits this panel.
    func localPoint(for point: Point, time: Float = 0) -> Point? {
        let screen = SIMD2(
            Float(point.x - hostRect.x),
            Float(point.y - hostRect.y)
        )
        guard let local = X3DPlaneHit.hit(
            screen: screen,
            viewSize: SIMD2(Float(hostRect.width), Float(hostRect.height)),
            planeSize: SIMD2(Float(planeSize.width), Float(planeSize.height)),
            camera: camera,
            model: model,
            time: time
        ) else { return nil }
        return Point(x: Double(local.x), y: Double(local.y))
    }
}
