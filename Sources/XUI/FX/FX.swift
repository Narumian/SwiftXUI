import Foundation

/// One effect's description, written as a value rather than a sequence of
/// calls. A composite effect returns more effects from `body`; a primitive
/// sets `Body == Never` and emits itself directly (see `_PrimitiveFX`).
///
/// This is `XView`'s shape exactly — same authoring, same one-shallow-level
/// erasure inside the walk, down to `Never` terminating a primitive's `Body`
/// — except the walk resolves down to `[any FX]` instead of layout nodes.
/// Pure data: nothing here touches state, which is what lets an effect be
/// asserted in a test without a renderer. What an app actually *does* with a
/// resolved `any FX` (draw it, play a sound, shake a camera) is entirely up
/// to that app — this protocol has no opinion, the same way `XView` has no
/// opinion about pixels.
public protocol FX {
    associatedtype Body: FX
    @XUIActor
    @FXBuilder var body: Body { get }
}

// `Never` already conforms to `XView` (see `Core/XView.swift`) with a
// `var body: Never { fatalError(...) }` witness — that same member also
// satisfies `FX`'s identically-shaped `body` requirement, so this
// conformance needs no separate implementation.
extension Never: FX {}

public extension FX where Body == Never {
    var body: Never {
        fatalError("\(type(of: self)) is a primitive FX — the walk should never read its body")
    }
}

/// An effect that resolves directly instead of having a `body`. The builder
/// aggregates (`TupleFX`, `ConditionalFX`, …) are primitives too — they
/// expand to zero or more resolved values, forwarding `id`/`store` to each
/// child so `@XState` inside a nested composite still resolves to stable,
/// identity-keyed storage.
public protocol _PrimitiveFX {
    @XUIActor
    func _emit(id: StateIdentity, store: StateStore, into out: inout [any FX])
}

@XUIActor
public extension _PrimitiveFX where Self: FX {
    /// The common case: a true leaf with nothing further to resolve just
    /// appends itself. Override only when a primitive needs to expand into
    /// something else (see the `FXBuilder` aggregates).
    func _emit(id: StateIdentity, store: StateStore, into out: inout [any FX]) {
        out.append(self)
    }
}

/// Walk any effect down to its resolved leaves. The only place `any FX`
/// appears.
///
/// `id`/`store` thread a stable structural identity through the walk so a
/// composite's `@XState` properties find the same persistent storage across
/// separate declarations of "the same" effect (see `StateIdentity`/
/// `StateStore`). `_installState` (real cost: a cast plus a dictionary lookup
/// per `@XState` property) only runs for `@Stateful`-attached composites —
/// this is a cold path, but there's no reason to pay it for the ordinary
/// one-shot beats.
@XUIActor
public func emit(_ fx: any FX, id: StateIdentity, store: StateStore, into out: inout [any FX]) {
    if let primitive = fx as? _PrimitiveFX {
        primitive._emit(id: id, store: store, into: &out)
        return
    }
    let childID = id.child(type: type(of: fx))
    if var stateful = fx as? any _Stateful {
        stateful._installState(id: childID, store: store)
        emit((stateful as! any FX).body, id: childID, store: store, into: &out)
        return
    }
    emit(fx.body, id: childID, store: store, into: &out)
}
