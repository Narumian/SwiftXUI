import Foundation

/// A synchronous two-way value connection for state on the current actor.
@propertyWrapper
public struct Binding<Value: Sendable>: Sendable {
    private let read: @Sendable () -> Value
    private let write: @Sendable (Value) -> Void

    public init(
        get: @escaping @Sendable () -> Value,
        set: @escaping @Sendable (Value) -> Void
    ) {
        self.read = get
        self.write = set
    }

    public var wrappedValue: Value {
        get { read() }
        nonmutating set { write(newValue) }
    }

    public var projectedValue: Binding { self }
}

/// A two-way value connection to state owned by an actor.
public struct ActorBinding<Value: Sendable>: Sendable {
    private let read: @Sendable () async -> Value
    private let write: @Sendable (Value) async -> Void

    public init(
        get: @escaping @Sendable () async -> Value,
        set: @escaping @Sendable (Value) async -> Void
    ) {
        self.read = get
        self.write = set
    }

    public func get() async -> Value {
        await read()
    }

    public func set(_ value: Value) async {
        await write(value)
    }
}
