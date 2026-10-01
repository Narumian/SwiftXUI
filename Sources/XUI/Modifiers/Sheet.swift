import Foundation

/// The layer a sheet paints above its base: a dimming scrim that dismisses on tap,
/// with the sheet's content centred on top. Scrim taps register after the
/// content so the content's own taps win the first-match hit test.
struct _SheetLayer<Content: XView>: XView, _PrimitiveXView {
    typealias Body = Never
    let scrim: Color
    let scope: FocusScopeID
    let onDismiss: @Sendable () -> Void
    let content: Content

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let scrimNode = LayoutNode(layout: PassthroughLayout(),
                                   children: await lower(scrim, id: id.child(type: Color.self, index: 0), store: store))
        let contentNode = LayoutNode(layout: PassthroughLayout(),
                                     children: await lower(content, id: id.child(type: Content.self, index: 1), store: store))
        let layer = LayoutNode(layout: ZStackLayout(alignment: .center), children: [scrimNode, contentNode])
        layer.tapGesture = onDismiss
        layer.tapGestureID = "sheet-dismiss"
        layer.tapGestureLabel = "閉じる"
        layer.tapGestureAfterChildren = true
        layer.focusScopeOverride = scope
        return [layer]
    }
}

public struct _SheetModifier<Content: XView, Sheet: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let isPresented: Bool
    let scope: FocusScopeID
    let scrim: Color
    let onDismiss: @Sendable () -> Void
    let sheet: Sheet

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let base = LayoutNode(layout: PassthroughLayout(),
                              children: await lower(content, id: id.child(type: Content.self, index: 0), store: store))
        guard isPresented else { return [base] }
        base.blocksInput = true
        let layer = LayoutNode(
            layout: PassthroughLayout(),
            children: await lower(_SheetLayer(scrim: scrim, scope: scope, onDismiss: onDismiss, content: sheet),
                            id: id.child(type: Sheet.self, index: 1), store: store))
        return [LayoutNode(layout: DecorationLayout(kind: .overlay, alignment: .center), children: [base, layer])]
    }
}

public extension XView {
    /// A dominant modal layer centred over this view: a scrim, then `content`.
    /// Size the content with `.frame(width: .fraction(.golden), ...)`; the layer
    /// offers it the whole base area. While presented, this view still paints but
    /// yields no regions, controls or taps; tapping the scrim calls `onDismiss`,
    /// and the sheet's controls report `scope` so focus stays inside it.
    /// The caller owns `isPresented` and flips it from `onDismiss`.
    func sheet<Sheet: XView>(
        isPresented: Bool,
        scope: FocusScopeID = "sheet",
        scrim: Color = Color(red: 0, green: 0, blue: 0, opacity: 0.6),
        onDismiss: @escaping @Sendable () -> Void,
        @XViewBuilder content: () -> Sheet
    ) -> _SheetModifier<Self, Sheet> {
        _SheetModifier(content: self, isPresented: isPresented, scope: scope, scrim: scrim,
                       onDismiss: onDismiss, sheet: content())
    }
}
