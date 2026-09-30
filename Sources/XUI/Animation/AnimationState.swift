import Foundation

/// One animated value: where it started, where it is going, and how.
///
/// Feeding it the target every frame is the whole interface: it notices the
/// target changed and, if the transaction says to animate, starts moving from
/// wherever the value is *now* (so a target that changes mid-flight bends the
/// motion instead of restarting it). Otherwise the value jumps.
struct AnimationState<Value: Animatable> {
    private(set) var from: Value
    private(set) var to: Value
    private var start: Double = 0
    private var animation: Animation?

    /// The first frame a value exists it is simply there: nothing animates in.
    init(_ value: Value) {
        from = value
        to = value
    }

    /// The value at `now`.
    func shown(at now: Double) -> Value {
        guard let animation else { return to }
        let elapsed = now - start
        if elapsed >= animation.totalDuration { return to }
        return Value.interpolate(from: from, to: to, at: animation.progress(elapsed: elapsed))
    }

    var isMoving: Bool { animation != nil }

    /// Advances to `now` with this frame's `target`, returning the value to use.
    mutating func update(target: Value, now: Double, transaction: Transaction) -> Value {
        if target != to {
            let current = shown(at: now)
            if transaction.animates, let animation = transaction.animation {
                from = current
                to = target
                start = now
                self.animation = animation
            } else {
                from = target
                to = target
                self.animation = nil
            }
        }
        if let animation, now - start >= animation.totalDuration {
            from = to
            self.animation = nil
        }
        return shown(at: now)
    }
}

public extension StateStore {
    /// The value an animatable modifier should use this frame for `target`.
    ///
    /// Outside any `.animation(_:value:)` this is just `target` and costs
    /// nothing. Inside one, the value is kept per identity and eased toward
    /// `target` on the host's presentation clock.
    func animated<Value: Animatable>(_ target: Value, id: StateIdentity) -> Value {
        guard transaction.isActive else { return target }
        let box = box(for: id) { AnimationState(target) }
        return box.value.update(target: target, now: clock, transaction: transaction)
    }
}
