import Foundation

/// A primitive view: one that produces layout nodes directly instead of a
/// `body`. Builder aggregates (`TupleView`, `ConditionalView`, …) are primitives
/// too — they expand to zero or more nodes, forwarding `id`/`store` to each
/// child so `@XState` inside a nested composite still resolves to stable,
/// identity-keyed storage. True leaves (`Color`, `Text`, …) have no `XView`
/// children and ignore both.
protocol _PrimitiveXView {
    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode]
}

/// Lower any view to its layout nodes. A view that is not a primitive is
/// expanded through its `body`; this is the only place `any XView` appears.
///
/// `id`/`store` thread a stable structural identity through the walk so a
/// composite's `@XState` properties find the same persistent storage across
/// separate frames (see `StateIdentity`/`StateStore`). The `id.child(type:)`
/// combine is O(1) and unconditional — cheap enough to pay on every node of
/// this per-frame walk. `_installState` (real cost: a cast plus a dictionary
/// lookup per `@XState` property) only runs for nodes that conform to
/// `_Stateful`.
///
/// `_PrimitiveXView` is checked before `IntrinsicView` on purpose — an
/// existential `as?` costs the same (~115ns, measured via `xview-bench`)
/// whether it succeeds or fails, and primitives vastly outnumber intrinsic
/// views (zero conformers exist in this package today), so trying the more
/// likely match first avoids a wasted attempt on the common case.
@XUIActor
func lower(_ view: any XView, id: StateIdentity, store: StateStore) async -> [LayoutNode] {
    if let primitive = view as? _PrimitiveXView {
        return await primitive._lower(id: id, store: store)
    }
    if let intrinsic = view as? any IntrinsicView {
        return intrinsic._lowerIntrinsicView()
    }
    let childID = id.child(type: type(of: view))
    if var dynamic = view as? any DynamicProperty {
        dynamic.update(id: childID, store: store)
        return await lower((dynamic as! any XView).body, id: childID, store: store)
    }
    return await lower(view.body, id: childID, store: store)
}
