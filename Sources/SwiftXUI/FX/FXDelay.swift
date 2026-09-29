import Foundation

/// A resolved leaf that should start `delay` seconds after the host received
/// it. The sink holds it until then; nesting `.delay` adds the delays up.
public struct ScheduledFX: FX, _PrimitiveFX {
    public typealias Body = Never
    public let leaf: any FX
    public let delay: Double

    public init(_ leaf: any FX, delay: Double) {
        if let inner = leaf as? ScheduledFX {
            self.leaf = inner.leaf
            self.delay = inner.delay + delay
        } else {
            self.leaf = leaf
            self.delay = delay
        }
    }
}

public struct _FXDelayModifier<Content: FX>: FX, _PrimitiveFX {
    public typealias Body = Never
    let content: Content
    let delay: Double

    public func _emit(id: StateIdentity, store: StateStore, into out: inout [any FX]) {
        var leaves: [any FX] = []
        emit(content, id: id, store: store, into: &leaves)
        for leaf in leaves { out.append(ScheduledFX(leaf, delay: delay)) }
    }
}

public extension FX {
    /// Start this effect `seconds` later. Purely a presentation offset — it
    /// never holds anything up.
    func delay(_ seconds: Double) -> _FXDelayModifier<Self> {
        _FXDelayModifier(content: self, delay: max(0, seconds))
    }
}
