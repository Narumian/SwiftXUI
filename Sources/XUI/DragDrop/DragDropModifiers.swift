import Foundation

/// `.draggable(_:)`: lets a press-and-hold (or a small drag, see `DragActivation`) lift this view.
/// While it is lifted the view shows an empty slot and a copy of it follows the pointer.
public struct _DraggableModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let typeID: ObjectIdentifier
    let payload: @Sendable () -> DragPayload
    let preview: AnyView?
    let activation: DragActivation
    let slotCornerRadius: Double
    let key: AnyHashable?

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let dragDrop = _EnvironmentObjectContext.currentOrEmpty.object(DragDropStore.self)
        let contentNode = LayoutNode(layout: PassthroughLayout(),
                                     children: await lower(content, id: id.child(type: Content.self, index: 0), store: store))
        var children = [contentNode]
        let key = key ?? AnyHashable(id)
        if dragDrop?.activeSourceID == key {
            // The slot the preview was lifted from.
            let slot = RoundedRectangle(cornerRadius: slotCornerRadius, fill: XColorValue(hex: 0x000000).opacity(0.5))
            children.append(LayoutNode(layout: PassthroughLayout(),
                                       children: await lower(slot, id: id.child(type: RoundedRectangle.self, index: 1), store: store)))
        }
        let node = LayoutNode(layout: DecorationLayout(kind: .overlay, alignment: .center), children: children)
        node.dragSource = DragSourceSpec(id: key, typeID: typeID, makePayload: payload,
                                         preview: preview ?? AnyView(content), activation: activation,
                                         cornerRadius: slotCornerRadius)
        return [node]
    }
}

public struct _DropDestinationModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let typeID: ObjectIdentifier
    let validate: @Sendable (DragPayload) -> Bool
    let perform: @Sendable (DragPayload, Point) -> Bool
    let targeted: @Sendable (Bool) -> Void
    let springLoad: (delay: Double, action: @Sendable () -> Void)?

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let node = LayoutNode(layout: PassthroughLayout(), children: await lower(content, id: id, store: store))
        node.dropTarget = DropTargetSpec(id: id, typeID: typeID, validate: validate, perform: perform,
                                         targeted: targeted, springLoad: springLoad)
        return [node]
    }
}

public struct _ContextMenuModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let items: @Sendable () -> [ContextMenuItem]

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let node = LayoutNode(layout: PassthroughLayout(), children: await lower(content, id: id, store: store))
        node.contextMenu = ContextMenuSpec(items: items)
        return [node]
    }
}

public extension XView {
    /// Makes this view draggable, carrying `payload`. The payload is only built when the view lifts.
    ///
    /// The preview that follows the pointer is this view itself; pass `preview:` for something else.
    /// `cornerRadius` rounds the empty slot and the backing of the preview. `id` names the item so the empty slot stays with it if the list shifts during the drag.
    /// A view that is also a `.contextMenu` opens its menu when it is lifted and released in place.
    func draggable<T: XTransferable>(
        _ payload: @autoclosure @escaping @Sendable () -> T,
        activation: DragActivation = .automatic,
        cornerRadius slotCornerRadius: Double = 0,
        id: AnyHashable? = nil
    ) -> _DraggableModifier<Self> {
        _DraggableModifier(content: self, typeID: ObjectIdentifier(T.self), payload: { DragPayload(payload()) },
                           preview: nil, activation: activation, slotCornerRadius: slotCornerRadius, key: id)
    }

    func draggable<T: XTransferable, Preview: XView>(
        _ payload: @autoclosure @escaping @Sendable () -> T,
        activation: DragActivation = .automatic,
        cornerRadius slotCornerRadius: Double = 0,
        id: AnyHashable? = nil,
        @XViewBuilder preview: () -> Preview
    ) -> _DraggableModifier<Self> {
        _DraggableModifier(content: self, typeID: ObjectIdentifier(T.self), payload: { DragPayload(payload()) },
                           preview: AnyView(preview()), activation: activation, slotCornerRadius: slotCornerRadius, key: id)
    }

    /// Accepts a dragged `T`. `action` gets the value and where it landed, and returns whether it was
    /// taken (false springs the preview back). `isTargeted` is told when a drag enters or leaves, for
    /// highlighting. `isValid` can refuse a particular value; a refused drag does not target this view.
    /// `springLoaded` runs once after a drag has hovered for `delay` seconds (open a folder).
    func dropDestination<T: XTransferable>(
        for type: T.Type = T.self,
        isValid: @escaping @Sendable (T) -> Bool = { _ in true },
        springLoaded: (delay: Double, action: @Sendable () -> Void)? = nil,
        isTargeted: @escaping @Sendable (Bool) -> Void = { _ in },
        action: @escaping @Sendable ([T], Point) -> Bool
    ) -> _DropDestinationModifier<Self> {
        _DropDestinationModifier(
            content: self, typeID: ObjectIdentifier(T.self),
            validate: { payload in payload.value(as: T.self).map(isValid) ?? false },
            perform: { payload, point in payload.value(as: T.self).map { action([$0], point) } ?? false },
            targeted: isTargeted, springLoad: springLoaded)
    }

    /// A menu for this view: a secondary click, a long press, or a lift released in place opens it.
    /// The items are built when it opens.
    func contextMenu(_ items: @escaping @Sendable () -> [ContextMenuItem]) -> _ContextMenuModifier<Self> {
        _ContextMenuModifier(content: self, items: items)
    }
}
