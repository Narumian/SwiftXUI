import Foundation

/// A two-way value connection between a parent and a child view.
///
/// A two-way asynchronous value connection. The async boundary is intentional:
/// actor-owned models can be bound without snapshots or hidden actor hops.
public struct Binding<Value: Sendable>: Sendable {
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
