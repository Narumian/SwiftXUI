import Foundation

/// Identity-keyed persistent storage for declarative-tree state (`@XState`,
/// shared by both `FX` and `XView`).
///
/// Not internally synchronized. Contract: touched only from the single
/// synchronous walk that owns it — never shared across threads. `@unchecked
/// Sendable` asserts that contract; it does not enforce it.
public final class StateStore: @unchecked Sendable {
    /// Public because `@XState`'s generated peer property (in whatever
    /// module uses it) is declared with this exact type — its `value`
    /// accessor is likewise public for the generated `get`/`set` to reach.
    /// `init` stays module-private: only `box(for:default:)` ever creates one.
    /// See `box(for:default:)`'s own comment for why an app can build its own
    /// `.onReceive`-shaped modifiers on top of this same type.
    public final class Box<Value>: @unchecked Sendable {
        public var value: Value
        /// Fires once, with the box's last `value`, the first time this
        /// identity goes an entire pass without being revisited — the
        /// identity-keyed equivalent of SwiftUI's `.onDisappear`, just set
        /// imperatively on the raw box (from a hand-written `_installState`)
        /// rather than through modifier syntax. Not cleared by anything
        /// other than firing — reassign it if the meaning of "removed"
        /// changes across a box's lifetime.
        public var onRemove: ((Value) -> Void)?
        init(_ value: Value) { self.value = value }
    }

    private var boxes: [StateIdentity: AnyObject] = [:]
    private var reachedThisPass: Set<StateIdentity> = []

    /// The host's presentation clock for the pass being declared (seconds).
    /// Lowering has no environment, so animatable modifiers read it here.
    public internal(set) var clock: Double = 0
    /// The animation context of the subtree being declared right now. Set by
    /// `.animation(_:value:)` for its content and restored after it.
    public internal(set) var transaction = Transaction()

    public init() {}

    /// The identity-keyed box for `id`, creating it from `make` the first
    /// time it's asked for. Public so an app can author its own `.onReceive`/
    /// `.onRemove`-shaped modifiers (typically keyed by `id.child(type:
    /// SomeModifier.self)`, the same convention `XUI`'s own modifiers
    /// use) without needing anything more from this module.
    public func box<Value>(for id: StateIdentity, default make: () -> Value) -> Box<Value> {
        reachedThisPass.insert(id)
        if let existing = boxes[id] as? Box<Value> { return existing }
        let created = Box(make())
        boxes[id] = created
        return created
    }

    /// The one entry point `@Stateful`-generated `_installState` calls
    /// (possibly from another module) — keyed by property name instead of
    /// by type, the addressing scheme `@XState` needs to disambiguate
    /// several properties on the same node.
    public func _xstateBox<Value>(id: StateIdentity, name: String, default make: () -> Value) -> Box<Value> {
        box(for: id.child(name: name), default: make)
    }

    /// Call once at the start of a full re-declaration pass over the tree.
    /// `now` is the host's presentation clock (`fxTime`), for animation.
    public func beginPass(now: Double = 0) {
        reachedThisPass.removeAll(keepingCapacity: true)
        clock = now
        transaction = Transaction()
    }

    /// Call once after the pass finishes: anything not re-visited this pass
    /// is gone, so state for a node that stopped being declared (an enemy
    /// died, an aura's condition cleared) doesn't leak forever — and, before
    /// it's dropped, fires its `onRemove` if one was set.
    public func endPass() {
        let dropped = boxes.filter { !reachedThisPass.contains($0.key) }
        boxes = boxes.filter { reachedThisPass.contains($0.key) }
        for (_, box) in dropped { (box as? _AnyRemovableBox)?.fireOnRemove() }
    }
}

/// Type-erased hook so `endPass` can fire `onRemove` on a `Box<Value>` for
/// any `Value` without knowing it — `boxes` stores them as plain `AnyObject`.
private protocol _AnyRemovableBox: AnyObject {
    func fireOnRemove()
}

extension StateStore.Box: _AnyRemovableBox {
    fileprivate func fireOnRemove() {
        onRemove?(value)
        onRemove = nil
    }
}
