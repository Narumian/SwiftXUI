import Foundation

public struct _AnchorModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let id: AnchorID

    @XUIActor
    func _lower(id stateID: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let wrapper = LayoutNode(layout: PassthroughLayout(), children: await lower(content, id: stateID, store: store))
        wrapper.anchor = id
        return [wrapper]
    }
}

public struct _RegionModifier<Content: XView>: @unchecked Sendable, XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let payload: AnyHashable

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let wrapper = LayoutNode(layout: PassthroughLayout(), children: await lower(content, id: id, store: store))
        wrapper.region = payload
        return [wrapper]
    }
}

public struct _ControlModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let control: XControl

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let wrapper = LayoutNode(layout: PassthroughLayout(), children: await lower(content, id: id, store: store))
        wrapper.control = control
        return [wrapper]
    }
}

public struct _TapGestureModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let id: String?
    let label: String?
    let action: @Sendable () -> Void
    let afterChildren: Bool

    @XUIActor
    func _lower(id stateID: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let wrapper = LayoutNode(layout: PassthroughLayout(), children: await lower(content, id: stateID, store: store))
        wrapper.tapGestureID = id
        wrapper.tapGestureLabel = label
        wrapper.tapGesture = action
        wrapper.tapGestureAfterChildren = afterChildren
        return [wrapper]
    }
}

public struct _DragGestureModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let gesture: DragGesture

    @XUIActor
    func _lower(id stateID: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let wrapper = LayoutNode(layout: PassthroughLayout(), children: await lower(content, id: stateID, store: store))
        wrapper.dragGesture = gesture
        return [wrapper]
    }
}

public struct _LongPressGestureModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let gesture: LongPressGesture

    @XUIActor
    func _lower(id stateID: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let wrapper = LayoutNode(layout: PassthroughLayout(), children: await lower(content, id: stateID, store: store))
        wrapper.longPressGesture = gesture
        return [wrapper]
    }
}

public struct _PressGestureModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let gesture: PressGesture

    @XUIActor
    func _lower(id stateID: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let wrapper = LayoutNode(layout: PassthroughLayout(), children: await lower(content, id: stateID, store: store))
        wrapper.pressGesture = gesture
        return [wrapper]
    }
}

public extension XView {
    /// Attach a value-style gesture to this view.
    ///
    /// This first overload bridges `TapGesture` to the existing tap resolver.
    /// More gesture types can be added without changing the view-facing API.
    func gesture(_ gesture: TapGesture) -> _TapGestureModifier<Self> {
        _TapGestureModifier(
            content: self,
            id: nil,
            label: nil,
            action: gesture._endedAction ?? {},
            afterChildren: false
        )
    }

    /// Attach a value-style drag gesture to this view.
    func gesture(_ gesture: DragGesture) -> _DragGestureModifier<Self> {
        _DragGestureModifier(content: self, gesture: gesture)
    }

    /// Attach a press gesture to this view: it reports the pointer going down and coming up. See `PressGesture`.
    func gesture(_ gesture: PressGesture) -> _PressGestureModifier<Self> {
        _PressGestureModifier(content: self, gesture: gesture)
    }

    /// Perform `pressed` when the pointer goes down on this view, and `ended` when that press ends (it is lifted
    /// or the touch is cancelled). `ended` always follows `pressed`.
    func onPressGesture(pressed: @escaping @Sendable () -> Void,
                        ended: @escaping @Sendable () -> Void) -> _PressGestureModifier<Self> {
        gesture(PressGesture().onPressed(pressed).onReleased(ended).onCancelled(ended))
    }

    /// Attach a long-press gesture to this view. See `LongPressGesture` for how it is recognized.
    func gesture(_ gesture: LongPressGesture) -> _LongPressGestureModifier<Self> {
        _LongPressGestureModifier(content: self, gesture: gesture)
    }

    /// Perform `action` when this view is pressed and held for `minimumDuration` seconds.
    func onLongPressGesture(minimumDuration: Double = 0.5,
                            perform action: @escaping @Sendable () -> Void) -> _LongPressGestureModifier<Self> {
        gesture(LongPressGesture(minimumDuration: minimumDuration).onEnded(action))
    }

    /// Export this view's resolved frame as `result.anchors[id]` — the
    /// replacement for the hand-computed rects on `BattleLayout`.
    func anchor(_ id: AnchorID) -> _AnchorModifier<Self> {
        _AnchorModifier(content: self, id: id)
    }

    /// Register this view's resolved frame as a hit region carrying `payload`
    /// (cast it back on the app side, e.g. to `PlayerAction` or a node id
    /// `String`). Collected into `result.regions`.
    func region<P: Hashable>(_ payload: P) -> _RegionModifier<Self> {
        _RegionModifier(content: self, payload: AnyHashable(payload))
    }

    /// Declare this view as a semantic control. Layout exports the resolved
    /// frame for every input adapter; XUI itself does not handle device input.
    func control(_ control: XControl) -> _ControlModifier<Self> {
        _ControlModifier(content: self, control: control)
    }

    /// Declarative tap entry point for static views. The action is collected
    /// into `RenderResult.tapGestures` and performed by the app after hit
    /// testing a pointer/touch against the resolved frame.
    func onTapGesture(_ action: @escaping @Sendable () -> Void) -> _TapGestureModifier<Self> {
        gesture(TapGesture().onEnded(action))
    }

    /// Declarative tap entry point with semantic metadata for accessibility,
    /// automation, and app-side interaction region export.
    func onTapGesture(id: String, label: String, _ action: @escaping @Sendable () -> Void) -> _TapGestureModifier<Self> {
        _TapGestureModifier(content: self, id: id, label: label, action: action, afterChildren: false)
    }

    /// Register this view's tap after its descendants, so child controls win and the view can
    /// still consume taps in its otherwise-empty area (for example, the body of a modal sheet).
    func onTapGesture(id: String, label: String, afterChildren: Bool,
                      _ action: @escaping @Sendable () -> Void) -> _TapGestureModifier<Self> {
        _TapGestureModifier(content: self, id: id, label: label, action: action, afterChildren: afterChildren)
    }

    /// Declarative payload tap entry point for static views. This exports the same
    /// payload-backed hit region as `.region(_:)`; the app decides how to route
    /// the payload when a pointer/touch ends inside the resolved frame.
    func onTapGesture<P: Hashable>(_ payload: P) -> _RegionModifier<Self> {
        region(payload)
    }
}
