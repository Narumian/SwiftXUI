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

public struct _RegionModifier<Content: XView>: XView, _PrimitiveXView {
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
    let action: () -> Void

    @XUIActor
    func _lower(id stateID: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let wrapper = LayoutNode(layout: PassthroughLayout(), children: await lower(content, id: stateID, store: store))
        wrapper.tapGestureID = id
        wrapper.tapGestureLabel = label
        wrapper.tapGesture = action
        return [wrapper]
    }
}

public extension XView {
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
    func onTapGesture(_ action: @escaping () -> Void) -> _TapGestureModifier<Self> {
        _TapGestureModifier(content: self, id: nil, label: nil, action: action)
    }

    /// Declarative tap entry point with semantic metadata for accessibility,
    /// automation, and app-side interaction region export.
    func onTapGesture(id: String, label: String, _ action: @escaping () -> Void) -> _TapGestureModifier<Self> {
        _TapGestureModifier(content: self, id: id, label: label, action: action)
    }

    /// Declarative payload tap entry point for static views. This exports the same
    /// payload-backed hit region as `.region(_:)`; the app decides how to route
    /// the payload when a pointer/touch ends inside the resolved frame.
    func onTapGesture<P: Hashable>(_ payload: P) -> _RegionModifier<Self> {
        region(payload)
    }
}
