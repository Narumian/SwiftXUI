import Foundation
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

/// Everything a leaf needs while painting: the canvas, the environment, and the
/// sinks for regions and anchors. Reference type — one instance per render.
public final class RenderContext {
    public let canvas: any XCanvas
    public var environment: EnvironmentValues
    public private(set) var regions: [ResolvedRegion] = []
    public private(set) var shaders: [ResolvedShader] = []
    public private(set) var controls: [ResolvedControl] = []
    public private(set) var tapGestures: [ResolvedTapGesture] = []
    public private(set) var anchors = AnchorMap()
    var inputSuspendedDepth = 0
    var focusScopeStack: [FocusScopeID] = []
    private var drawingOriginStack: [Point] = []

    private var acceptsInput: Bool { inputSuspendedDepth == 0 }

    init(canvas: any XCanvas, environment: EnvironmentValues) {
        self.canvas = canvas
        self.environment = environment
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
    }

    func addTapGesture(_ rect: Rect, id: String?, label: String?, action: @escaping () -> Void) {
        guard acceptsInput else { return }
        tapGestures.append(ResolvedTapGesture(rect: rect, id: id, label: label, action: action))
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
    public var anchors: AnchorMap

    public init(
        regions: [ResolvedRegion],
        shaders: [ResolvedShader] = [],
        controls: [ResolvedControl] = [],
        tapGestures: [ResolvedTapGesture] = [],
        anchors: AnchorMap
    ) {
        self.regions = regions
        self.shaders = shaders
        self.controls = controls
        self.tapGestures = tapGestures
        self.anchors = anchors
    }

    /// First region whose payload is of type `T`, hit-tested against `point`.
    public func hit<T>(_ point: Point, as type: T.Type = T.self) -> T? {
        for region in regions where region.rect.contains(point) {
            if let match = region.payload.base as? T { return match }
        }
        return nil
    }

    /// Perform the first closure tap gesture whose resolved rect contains
    /// `point`. Returns whether a gesture handled the point.
    @discardableResult
    public func tap(_ point: Point) -> Bool {
        for gesture in tapGestures where gesture.rect.contains(point) {
            gesture.perform()
            return true
        }
        return false
    }
}
