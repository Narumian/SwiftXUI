import Foundation

private struct FXApplyKey: EnvironmentKey {
    static var defaultValue: ((any FX, Point) -> Void)? { nil }
}

public extension EnvironmentValues {
    /// The app's one registered interpreter for a resolved `any FX` value —
    /// set once (e.g. where `LayoutHost.render`'s `environment` is built),
    /// not per `.fx()` call site. `.fx()` does nothing if this is unset.
    var fxApply: ((any FX, Point) -> Void)? {
        get { self[FXApplyKey.self] }
        set { self[FXApplyKey.self] = newValue }
    }
}

/// Subscribes to `signal` once (identity-keyed, same as `.onReceive`), but
/// defers *applying* what it receives until this node's own `draw` call —
/// the moment `LayoutEngine.render` hands it this frame's freshly resolved
/// `Rect`. A value sent to `signal` during `apply()`/`update()` (before this
/// frame's layout has even run) still lands on this frame's real position,
/// not a stale one: sending only queues, and the queue drains at draw time.
public struct _FXSinkModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let signal: Signal<any FX>
    let anchor: Alignment
    let offset: Point

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let buffer: StateStore.Box<[any FX]> = store.box(for: id.child(type: Self.self, index: 0)) { [] }
        let sub: StateStore.Box<Subscription?> = store.box(for: id.child(type: Self.self, index: 1)) { nil }
        let playback: StateStore.Box<[any FXPlayback]> = store.box(for: id.child(type: Self.self, index: 2)) { [] }
        let pending: StateStore.Box<[(due: Double, leaf: any FX, point: Point)]> =
            store.box(for: id.child(type: Self.self, index: 4)) { [] }
        func dispatch(_ value: any FX, _ point: Point, at now: Double, _ context: RenderContext) {
            let leaf = (value as? ScheduledFX)?.leaf ?? value
            if let vfx = leaf as? any VFX {
                let next: any FXPlayback
                if let contextual = vfx as? any ContextualVFX {
                    next = contextual.makePlayback(in: FXPlaybackContext(
                        point: point, startedAt: now, environment: context.environment))
                } else {
                    next = vfx.makePlayback(at: point, startedAt: now)
                }
                if let keyed = next as? any ReplacingFXPlayback {
                    playback.value.removeAll {
                        ($0 as? any ReplacingFXPlayback)?.replacementKey == keyed.replacementKey
                    }
                }
                playback.value.append(next)
            } else if let apply = context.environment.fxApply {
                apply(leaf, point)
            }
        }
        if sub.value == nil {
            sub.value = signal.subscribe { buffer.value.append($0) }
        }

        let nodes = lower(content, id: id, store: store)
        guard let first = nodes.first else { return nodes }
        let previousDraw = first.draw
        first.draw = { rect, context in
            previousDraw?(rect, context)
            if !buffer.value.isEmpty {
                let incoming = buffer.value
                buffer.value.removeAll()
                let point = Point(x: rect.x + rect.width * anchor.horizontal.fraction + offset.x,
                                   y: rect.y + rect.height * anchor.vertical.fraction + offset.y)
                var leaves: [any FX] = []
                for value in incoming {
                    emit(value, id: id.child(type: Self.self, index: 3), store: store, into: &leaves)
                }
                let now = context.environment.fxTime
                for value in leaves {
                    if let scheduled = value as? ScheduledFX, scheduled.delay > 0 {
                        pending.value.append((now + scheduled.delay, scheduled.leaf, point))
                    } else {
                        dispatch(value, point, at: now, context)
                    }
                }
            }
            if !pending.value.isEmpty {
                let now = context.environment.fxTime
                let due = pending.value.filter { $0.due <= now }
                pending.value.removeAll { $0.due <= now }
                // Start at the scheduled time, not the frame that noticed it, so a
                // late frame doesn't shift the effect.
                for item in due { dispatch(item.leaf, item.point, at: item.due, context) }
            }
            let now = context.environment.fxTime
            playback.value.removeAll { item in
                item.step(now: now)
                item.draw(in: rect, context: context)
                return item.finished
            }
        }
        return nodes
    }
}

public extension XView {
    /// Declares that this node plays whatever `any FX` is sent to `signal`,
    /// at `anchor` (plus `offset`) within this node's own resolved rect. VFX
    /// leaves are driven and drawn here; other leaves use the optional app sink.
    func fx(_ signal: Signal<any FX>, anchor: Alignment = .center, offset: Point = .zero) -> _FXSinkModifier<Self> {
        _FXSinkModifier(content: self, signal: signal, anchor: anchor, offset: offset)
    }
}
