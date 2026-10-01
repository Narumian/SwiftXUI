import Foundation

/// Scales `content` up briefly whenever `signal` sends a value `matches`
/// accepts, then settles back over `frames` walks. A frame-counted pulse, not
/// a physically-decaying one — the view tree has no delta-time of its own to
/// integrate against (unlike `BattleFX`'s continuous fields, stepped from the
/// game's per-frame `ft`), so this counts walks instead of seconds. Built on
/// `Signal`: the subscription persists the same identity-keyed way
/// `.onReceive` uses, plus one more box for the countdown itself.
public struct _TriggerPulseModifier<Content: XView, Value: Sendable>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let signal: Signal<Value>
    let matches: @Sendable (Value) -> Bool
    let peakScale: Double
    let frames: Int

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let countdown: StateStore.Box<Int> = store.box(for: id.child(type: Self.self, index: 0)) { 0 }
        let subscription: StateStore.Box<Subscription?> = store.box(for: id.child(type: Self.self, index: 1)) { nil }
        if subscription.value == nil {
            subscription.value = signal.subscribe { value in
                if matches(value) { countdown.value = frames }
            }
        }

        let remaining = countdown.value
        countdown.value = max(0, remaining - 1)

        let t = Double(remaining) / Double(max(frames, 1))
        let scale = 1 + (peakScale - 1) * t
        return await lower(content.scaleEffect(x: scale, y: scale), id: id, store: store)
    }
}

public extension XView {
    /// Pulse this subtree's scale up to `peakScale` and back over `frames`
    /// walks whenever `signal` sends a value `matching` accepts.
    func trigger<Value: Sendable>(_ signal: Signal<Value>, matching: @escaping @Sendable (Value) -> Bool,
                         peakScale: Double = 1.15, frames: Int = 10) -> _TriggerPulseModifier<Self, Value> {
        _TriggerPulseModifier(content: self, signal: signal, matches: matching, peakScale: peakScale, frames: frames)
    }

    /// `trigger(_:matching:)` for an `Equatable` payload — react to one exact
    /// value.
    func trigger<Value: Equatable & Sendable>(_ signal: Signal<Value>, on value: Value,
                                    peakScale: Double = 1.15, frames: Int = 10) -> _TriggerPulseModifier<Self, Value> {
        trigger(signal, matching: { $0 == value }, peakScale: peakScale, frames: frames)
    }
}
