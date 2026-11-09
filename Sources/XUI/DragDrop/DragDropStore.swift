import Foundation

/// The one place that knows a drag is under way. Hosts share a single instance with the
/// views (as an environment object), the way they share `TextFocusStore`.
///
/// Everything here runs on the XUI actor. A drag never leaves XUI: the lifted preview is
/// drawn by the same renderer a frame at a time, so there is no system drag session to wait
/// for, and the value dragged is just a Swift value.
///
/// Sequence: a press on a `draggable` view is *pressing*; after the activation (a short hold,
/// or a little movement) it is *lifted* and the pointer is captured; releasing over a
/// `dropDestination` that accepts the value drops it, releasing where it was lifted opens the
/// view's context menu, releasing anywhere else springs the preview back.
public final class DragDropStore: @unchecked Sendable {
    public enum Feedback: Sendable { case lift, target, drop }

    // MARK: Configuration

    /// What `.automatic` means. A host with a precise pointer sets `.movement`.
    public var automaticActivation: DragActivation = .hold(0.25)
    /// How far a press may wander, in canvas units, and still count as held in place.
    public var slop: Double = 24
    /// How long a view that only has a context menu is held before the menu opens.
    public var menuHold: Double = 0.4
    /// For haptics: called when something lifts, a target is entered, a drop lands.
    public var onFeedback: (@Sendable (Feedback) -> Void)?
    /// Set by the host: stops the gesture runtime's sequence for a pointer the drag takes over
    /// (a scroll that had begun, a pending tap).
    public var capturePointer: (@Sendable (Int) -> Void)?

    public init() {}

    // MARK: State

    struct Press {
        var pointerID: Int
        var start: Point
        var last: Point
        var startClock: Double
        var source: ResolvedDragSource?
        var menu: ResolvedContextMenu?
    }

    struct Session {
        var pointerID: Int
        var source: ResolvedDragSource
        var payload: DragPayload
        var start: Point
        var position: Point
        var liftClock: Double
        var menu: ResolvedContextMenu?
        var target: ResolvedDropTarget?
        var hoverClock: Double
        var springFired: Bool
    }

    struct Pose {
        var origin: Point
        var scale: Double
    }

    struct Settle {
        var from: Pose
        var to: Pose
        var start: Double
        var animation: Animation
        var size: Size
        var preview: AnyView
        var cornerRadius: Double
        var sourceID: AnyHashable
    }

    struct MenuState {
        var items: [ContextMenuItem]
        var anchor: Point
        var openClock: Double
    }

    enum Phase {
        case idle
        case pressing(Press)
        case dragging(Session)
        case settling(Settle)
    }

    private(set) var phase: Phase = .idle
    private(set) var menu: MenuState?
    private(set) var clock = 0.0
    private var layout: RenderResult?

    static let lift = Animation.spring(response: 0.3, dampingFraction: 0.75)
    static let liftScale = 0.05
    static let cancelAnimation = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let restAnimation = Animation.spring(response: 0.2, dampingFraction: 0.9)
    static let dropAnimation = Animation.easeOut(duration: 0.18)

    /// Whether a context menu is open.
    public var isMenuOpen: Bool { menu != nil }

    /// True from the lift until the preview has landed.
    public var isDragging: Bool {
        switch phase {
        case .dragging, .settling: true
        default: false
        }
    }

    /// The view being dragged, so it can show an empty slot.
    var activeSourceID: AnyHashable? {
        switch phase {
        case .dragging(let s): s.source.spec.id
        case .settling(let s): s.sourceID
        default: nil
        }
    }

    // MARK: Frame

    /// Called by the host before it builds a frame.
    public func beginFrame(clock: Double) { self.clock = clock }

    /// Called by the host with the frame it just built: time-driven steps happen here.
    public func endFrame(_ layout: RenderResult) {
        self.layout = layout
        switch phase {
        case .pressing(let p):
            if let source = p.source {
                if case .hold(let seconds) = resolved(source.spec.activation), clock - p.startClock >= seconds {
                    lift(p, at: p.last)
                }
            } else if let spec = p.menu, clock - p.startClock >= menuHold {
                phase = .idle
                capturePointer?(p.pointerID)
                open(spec, at: p.last)
                onFeedback?(.lift)
            }
        case .dragging(var s):
            retarget(&s)
            phase = .dragging(s)
        case .settling(let s):
            if clock - s.start >= s.animation.totalDuration { phase = .idle }
        case .idle:
            break
        }
    }

    // MARK: Pointer

    /// Feeds one pointer sample. Returns true when the drag owns the sample. A press that
    /// might become a drag is *not* owned until it lifts, so taps and scrolls still work.
    @discardableResult
    public func handle(_ input: PointerInput, in layout: RenderResult) -> Bool {
        self.layout = layout
        if case .settling = phase, input.phase == .began { phase = .idle }
        switch phase {
        case .idle:
            guard input.phase == .began, menu == nil else { return false }
            let source = layout.dragSources.first { $0.rect.contains(input.position) }
            let spec = layout.contextMenus.first { $0.rect.contains(input.position) }
            guard source != nil || spec != nil else { return false }
            phase = .pressing(Press(pointerID: input.id, start: input.position, last: input.position,
                                    startClock: clock, source: source, menu: spec))
            return false

        case .pressing(var p):
            guard input.id == p.pointerID else { return false }
            switch input.phase {
            case .moved:
                p.last = input.position
                let distance = Self.distance(p.start, input.position)
                if let source = p.source, case .movement(let threshold) = resolved(source.spec.activation), distance >= threshold {
                    lift(p, at: input.position)
                    return true
                }
                phase = distance > slop ? .idle : .pressing(p)
                return false
            case .ended, .cancelled:
                phase = .idle
                return false
            case .began:
                return false
            }

        case .dragging(var s):
            guard input.id == s.pointerID else { return true }
            switch input.phase {
            case .moved:
                s.position = input.position
                retarget(&s)
                phase = .dragging(s)
            case .ended:
                s.position = input.position
                finish(s)
            case .cancelled:
                s.target?.spec.targeted(false)
                settle(s, to: .cancel)
            case .began:
                break
            }
            return true

        case .settling:
            return false
        }
    }

    /// A secondary click (or a long press the shell reports): opens the context menu under `point`.
    @discardableResult
    public func contextClick(at point: Point) -> Bool {
        guard menu == nil, let spec = layout?.contextMenus.first(where: { $0.rect.contains(point) }) else { return false }
        open(spec, at: point)
        return true
    }

    public func closeMenu() { menu = nil }

    // MARK: Steps

    private func resolved(_ activation: DragActivation) -> DragActivation {
        if case .automatic = activation { return automaticActivation }
        return activation
    }

    private func lift(_ p: Press, at point: Point) {
        guard let source = p.source else { phase = .idle; return }
        capturePointer?(p.pointerID)
        phase = .dragging(Session(pointerID: p.pointerID, source: source, payload: source.spec.makePayload(),
                                  start: point, position: point, liftClock: clock, menu: p.menu,
                                  target: nil, hoverClock: clock, springFired: false))
        onFeedback?(.lift)
    }

    /// Finds what is under the pointer and tells targets when they are entered or left.
    private func retarget(_ s: inout Session) {
        let found = layout?.dropTargets.first {
            $0.rect.contains(s.position) && $0.spec.typeID == s.payload.typeID && $0.spec.validate(s.payload)
        }
        if found?.spec.id != s.target?.spec.id {
            s.target?.spec.targeted(false)
            found?.spec.targeted(true)
            s.target = found
            s.hoverClock = clock
            s.springFired = false
            if found != nil { onFeedback?(.target) }
        }
        if let target = s.target, let spring = target.spec.springLoad, !s.springFired, clock - s.hoverClock >= spring.delay {
            s.springFired = true
            spring.action()
        }
    }

    private enum Landing { case drop(Rect), cancel, rest }

    private func finish(_ s: Session) {
        s.target?.spec.targeted(false)
        let inPlace = Self.distance(s.position, s.start) <= slop
        if inPlace, let spec = s.menu {
            settle(s, to: .rest)
            open(spec, at: s.position)
        } else if let target = layout?.dropTargets.first(where: {
            $0.rect.contains(s.position) && $0.spec.typeID == s.payload.typeID && $0.spec.validate(s.payload)
        }), target.spec.perform(s.payload, s.position) {
            onFeedback?(.drop)
            settle(s, to: .drop(target.rect))
        } else {
            settle(s, to: .cancel)
        }
    }

    private func settle(_ s: Session, to landing: Landing) {
        guard let frame = previewPose(of: s) else { phase = .idle; return }
        let size = s.source.rect.size
        let home = Pose(origin: Point(x: s.source.rect.x, y: s.source.rect.y), scale: 1)
        let to: Pose
        let animation: Animation
        switch landing {
        case .drop(let rect):
            to = Pose(origin: Point(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), scale: 0.4)
            animation = Self.dropAnimation
        case .cancel:
            to = home
            animation = Self.cancelAnimation
        case .rest:
            to = home
            animation = Self.restAnimation
        }
        phase = .settling(Settle(from: frame, to: to, start: clock, animation: animation, size: size,
                                 preview: s.source.spec.preview, cornerRadius: s.source.spec.cornerRadius, sourceID: s.source.spec.id))
    }

    private func open(_ spec: ResolvedContextMenu, at point: Point) {
        let items = spec.spec.items().enumerated().map { $1.numbered($0) }
        guard !items.isEmpty else { return }
        menu = MenuState(items: items, anchor: point, openClock: clock)
    }

    // MARK: Preview

    private func previewPose(of s: Session) -> Pose? {
        let progress = Self.lift.progress(elapsed: clock - s.liftClock)
        return Pose(origin: Point(x: s.source.rect.x + s.position.x - s.start.x, y: s.source.rect.y + s.position.y - s.start.y),
                    scale: 1 + Self.liftScale * progress)
    }

    /// What to draw for the floating preview this frame, if anything.
    struct Preview {
        var pose: Pose
        var size: Size
        var view: AnyView
        var cornerRadius: Double
    }

    var preview: Preview? {
        switch phase {
        case .dragging(let s):
            guard let pose = previewPose(of: s) else { return nil }
            return Preview(pose: pose, size: s.source.rect.size, view: s.source.spec.preview,
                           cornerRadius: s.source.spec.cornerRadius)
        case .settling(let s):
            let elapsed = clock - s.start
            guard elapsed < s.animation.totalDuration else { return nil }
            let t = s.animation.progress(elapsed: elapsed)
            let pose = Pose(origin: Point(x: s.from.origin.x + (s.to.origin.x - s.from.origin.x) * t,
                                          y: s.from.origin.y + (s.to.origin.y - s.from.origin.y) * t),
                            scale: s.from.scale + (s.to.scale - s.from.scale) * t)
            return Preview(pose: pose, size: s.size, view: s.preview, cornerRadius: s.cornerRadius)
        default:
            return nil
        }
    }

    private static func distance(_ a: Point, _ b: Point) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
