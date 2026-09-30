import Foundation

/// A two-way value connection between a parent and a child view.
///
/// `Binding` only transports reads and writes. It does not schedule a render
/// or perform actor hops; the object captured by `get` and `set` owns those
/// responsibilities. Like `StateStore`, it is intended for the thread that
/// owns the current view tree.
@propertyWrapper
@dynamicMemberLookup
public struct Binding<Value>: @unchecked Sendable {
    private let read: () -> Value
    private let write: (Value) -> Void

    public init(
        get: @escaping () -> Value,
        set: @escaping (Value) -> Void
    ) {
        self.read = get
        self.write = set
    }

    public var wrappedValue: Value {
        get { read() }
        nonmutating set { write(newValue) }
    }

    public var projectedValue: Binding<Value> { self }

    public subscript<Member>(dynamicMember keyPath: WritableKeyPath<Value, Member>) -> Binding<Member> {
        Binding<Member>(
            get: { wrappedValue[keyPath: keyPath] },
            set: { newValue in
                var value = wrappedValue
                value[keyPath: keyPath] = newValue
                wrappedValue = value
            }
        )
    }
}
