/// Something that can stop delivery. Same contract as Combine's `Cancellable`.
public protocol XCancellable {
    func cancel()
}

/// Cancels the wrapped work when `cancel()` is called or when the last reference goes away —
/// the only way to unsubscribe, same as Combine's `AnyCancellable`. Cancelling twice, or
/// letting it deinit after an explicit `cancel()`, is harmless.
///
/// XCombine as a whole is thread-confined: build, subscribe, send and cancel from the one
/// thread (or actor) that owns a graph. `@unchecked Sendable` only lets a value type that
/// holds one stay `Sendable`.
public final class XAnyCancellable: XCancellable, Hashable, @unchecked Sendable {
    @usableFromInline @exclusivity(unchecked) var base: (any XCancellable)?

    public init(_ cancel: @escaping () -> Void) {
        base = _ClosureCancellable(cancel)
    }

    @inlinable public init<C: XCancellable>(_ canceller: C) {
        base = canceller
    }

    @inlinable public func cancel() {
        guard let base else { return }
        self.base = nil
        base.cancel()
    }

    deinit { cancel() }

    public static func == (lhs: XAnyCancellable, rhs: XAnyCancellable) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

@usableFromInline final class _ClosureCancellable: XCancellable {
    @usableFromInline @exclusivity(unchecked) var onCancel: (() -> Void)?
    @inlinable init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    @inlinable func cancel() {
        let f = onCancel
        onCancel = nil
        f?()
    }
}

public extension XAnyCancellable {
    /// Keeps this subscription alive for as long as `set` holds it.
    func store(in set: inout Set<XAnyCancellable>) { set.insert(self) }
    func store<C: RangeReplaceableCollection>(in collection: inout C) where C.Element == XAnyCancellable {
        collection.append(self)
    }
}
