import Foundation

/// Wraps an app's content so that a lifted view floats above everything (sheets included) and a
/// context menu can open. Like `TextInputArea`, it is the one place the layers are drawn.
public struct DragDropArea<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never

    let content: Content

    public init(@XViewBuilder content: () -> Content) { self.content = content() }

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let dragDrop = _EnvironmentObjectContext.currentOrEmpty.object(DragDropStore.self)
        let base = LayoutNode(layout: PassthroughLayout(),
                              children: await lower(content, id: id.child(type: Content.self, index: 0), store: store))
        var children = [base]
        if let dragDrop {
            if dragDrop.menu != nil { base.blocksInput = true }
            if let shown = dragDrop.preview {
                let host = LayoutNode(layout: AbsoluteLayout(frame: Rect(x: shown.pose.origin.x, y: shown.pose.origin.y,
                                                                         width: shown.size.width, height: shown.size.height)),
                                      children: [])
                let inner = LayoutNode(layout: PassthroughLayout(),
                                       children: await lower(shown.view, id: id.child(type: AnyView.self, index: 1), store: store))
                let scale = shown.pose.scale
                inner.transformInFrame = { rect in
                    let c = Point(x: rect.midX, y: rect.midY)
                    return XTransform.translation(x: -c.x, y: -c.y).concatenating(.scale(x: scale, y: scale)).concatenating(.translation(x: c.x, y: c.y))
                }
                // Lift shadow: grows with the lift.
                let lift = max(0, min(1, (scale - 1) / DragDropStore.liftScale))
                let radius = shown.cornerRadius
                inner.draw = { rect, context in
                    context.canvas.fillRoundedRect(rect.offsetBy(dx: 0, dy: 4 + 6 * lift), cornerRadius: radius,
                                                   color: XColorValue(hex: 0x000000).opacity(0.18 + 0.2 * lift))
                    // An opaque backing, so what is underneath does not show through the preview.
                    context.canvas.fillRoundedRect(rect, cornerRadius: radius, color: XColorValue(hex: 0x2c2f33))
                }
                inner.blocksInput = true
                host.children = [inner]
                children.append(host)
            }
            if let menu = dragDrop.menu {
                children.append(await menuLayer(menu, dragDrop: dragDrop, id: id, store: store))
            }
        }
        return [LayoutNode(layout: PassthroughLayout(), children: children)]
    }

    @XUIActor
    private func menuLayer(_ menu: DragDropStore.MenuState, dragDrop: DragDropStore, id: StateIdentity, store: StateStore) async -> LayoutNode {
        let panel = ContextMenuPanel(items: menu.items, close: { [weak dragDrop] in dragDrop?.closeMenu() })
        let scrim = LayoutNode(layout: PassthroughLayout(),
                               children: await lower(Color(red: 0, green: 0, blue: 0, opacity: 0.0), id: id.child(type: Color.self, index: 2), store: store))
        let panelNode = LayoutNode(layout: PassthroughLayout(),
                                   children: await lower(panel, id: id.child(type: ContextMenuPanel.self, index: 3), store: store))
        let progress = Animation.spring(response: 0.25, dampingFraction: 0.8).progress(elapsed: store.clock - menu.openClock)
        let scale = 0.9 + 0.1 * progress
        let anchor = menu.anchor
        panelNode.transformInFrame = { rect in
            let c = Point(x: max(rect.x, min(rect.maxX, anchor.x)), y: anchor.y < rect.midY ? rect.y : rect.maxY)
            return XTransform.translation(x: -c.x, y: -c.y).concatenating(.scale(x: scale, y: scale)).concatenating(.translation(x: c.x, y: c.y))
        }
        let layer = LayoutNode(layout: MenuPlacementLayout(anchor: menu.anchor), children: [scrim, panelNode])
        layer.tapGesture = { [weak dragDrop] in dragDrop?.closeMenu() }
        layer.tapGestureID = "context-menu-dismiss"
        layer.tapGestureLabel = "閉じる"
        layer.tapGestureAfterChildren = true
        return layer
    }
}

/// Puts its one child at a fixed absolute frame.
struct AbsoluteLayout: NodeLayout {
    let frame: Rect
    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        proposal.resolved(fallback: context.referenceSize)
    }
    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        children.first?.frame = frame
    }
}

/// A scrim over the whole area and a panel next to the point that opened it, flipped above it
/// when there is no room below and kept inside the area.
struct MenuPlacementLayout: NodeLayout {
    let anchor: Point

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        proposal.resolved(fallback: context.referenceSize)
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        guard children.count == 2 else { return }
        children[0].frame = rect
        let panel = children[1]
        let size = LayoutEngine.measure(panel, ProposedSize(rect.size), context)
        let margin = 8.0, gap = 10.0
        let x = max(rect.x + margin, min(anchor.x - size.width / 2, rect.maxX - size.width - margin))
        var y = anchor.y + gap
        if y + size.height > rect.maxY - margin { y = anchor.y - size.height - gap }
        y = max(rect.y + margin, y)
        panel.frame = Rect(x: x, y: y, width: size.width, height: size.height)
    }
}

struct ContextMenuPanel: XView {
    let items: [ContextMenuItem]
    let close: @Sendable () -> Void

    var body: some XView {
        let close = close
        VStack(spacing: 0) {
            ForEach(items) { item in
                Text(item.title, size: 15, color: item.role == .destructive ? XColorValue(hex: 0xff7a70) : XColorValue(hex: 0xeaeced))
                    .padding(14)
                    .frame(width: .pt(220), alignment: .leading)
                    .onTapGesture(id: "context-menu.\(item.id)", label: item.title) {
                        close()
                        item.action()
                    }
            }
        }.background { RoundedRectangle(cornerRadius: 12, fill: XColorValue(hex: 0x2c2f33)) }
    }
}
