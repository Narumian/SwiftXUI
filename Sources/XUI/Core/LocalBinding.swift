/// A synchronous binding used by state owned by the XUI declaration walk.
/// Actor-owned models use `Binding` instead.
@propertyWrapper
@dynamicMemberLookup
public struct LocalBinding<Value> {
    private let read: () -> Value
    private let write: (Value) -> Void

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.read = get
        self.write = set
    }

    public var wrappedValue: Value {
        get { read() }
        nonmutating set { write(newValue) }
    }

    public var projectedValue: LocalBinding<Value> { self }

    public subscript<Member>(dynamicMember keyPath: WritableKeyPath<Value, Member>) -> LocalBinding<Member> {
        LocalBinding<Member>(
            get: { wrappedValue[keyPath: keyPath] },
            set: { newValue in
                var value = wrappedValue
                value[keyPath: keyPath] = newValue
                wrappedValue = value
            }
        )
    }
}
