import Foundation

enum _XUIBindingContext {
    @TaskLocal static var store: StateStore?
}

private final class _BindingStorage: @unchecked Sendable {
    private var notify: (@Sendable () -> Void)?

    func attach(to store: StateStore?) {
        guard let store else { return }
        notify = { [weak store] in
            Task { @XUIActor in store?.onChange?() }
        }
    }

    func invalidate() {
        notify?()
    }
}

/// A synchronous two-way value connection for state on the current actor.
@propertyWrapper
public struct Binding<Value: Sendable>: Sendable {
    private let read: @Sendable () -> Value
    private let write: @Sendable (Value) -> Void
    private let storage: _BindingStorage

    public init(
        get: @escaping @Sendable () -> Value,
        set: @escaping @Sendable (Value) -> Void
    ) {
        self.read = get
        self.write = set
        self.storage = _BindingStorage()
    }

    public var wrappedValue: Value {
        get {
            storage.attach(to: _XUIBindingContext.store)
            return read()
        }
        nonmutating set {
            storage.attach(to: _XUIBindingContext.store)
            write(newValue)
            storage.invalidate()
        }
    }

    public var projectedValue: Binding { self }
}

/// A two-way value connection to state owned by an actor.
public struct ActorBinding<Value: Sendable>: Sendable {
    private let read: @Sendable () async -> Value
    private let write: @Sendable (Value) async -> Void
    private let storage: _BindingStorage

    public init(
        get: @escaping @Sendable () async -> Value,
        set: @escaping @Sendable (Value) async -> Void
    ) {
        self.read = get
        self.write = set
        self.storage = _BindingStorage()
    }

    public func get() async -> Value {
        storage.attach(to: _XUIBindingContext.store)
        return await read()
    }

    public func set(_ value: Value) async {
        storage.attach(to: _XUIBindingContext.store)
        await write(value)
        storage.invalidate()
    }
}
