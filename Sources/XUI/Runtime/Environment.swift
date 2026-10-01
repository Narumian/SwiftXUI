import Foundation

public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

public struct EnvironmentValues {
    private var storage: [ObjectIdentifier: Any] = [:]
    private var environmentObjects: [ObjectIdentifier: AnyObject] = [:]

    public init() {}

    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { storage[ObjectIdentifier(key)] as? K.Value ?? K.defaultValue }
        set { storage[ObjectIdentifier(key)] = newValue }
    }
    
    public mutating func environmentObject<Object: AnyObject>(_ object: Object) {
        environmentObjects[ObjectIdentifier(Object.self)] = object
    }

    func _environmentObjectContext() -> _EnvironmentObjectContext.Values {
        _EnvironmentObjectContext.Values(environmentObjects)
    }
}

enum _EnvironmentObjectContext {
    final class Values: @unchecked Sendable {
        private let storage: [ObjectIdentifier: AnyObject]

        init(_ storage: [ObjectIdentifier: AnyObject]) {
            self.storage = storage
        }

        func object<Object: AnyObject>(_ type: Object.Type) -> Object? {
            storage[ObjectIdentifier(type)] as? Object
        }

        func inserting<Object: AnyObject>(_ object: Object) -> Values {
            var next = storage
            next[ObjectIdentifier(Object.self)] = object
            return Values(next)
        }
    }

    @TaskLocal static var current: Values?

    static var currentOrEmpty: Values {
        current ?? Values([:])
    }
}

@propertyWrapper
public struct EnvironmentObject<Object: AnyObject> {
    public init() {}

    public var wrappedValue: Object {
        guard let value = _EnvironmentObjectContext.current?.object(Object.self) else {
            fatalError(
                "No environment object of type \(Object.self) was found. " +
                "Inject it with EnvironmentValues.environmentObject(_:)."
            )
        }
        return value
    }
}

public enum LayoutDirection: Hashable, Sendable {
    case leftToRight
    case rightToLeft
}

private enum LayoutDirectionKey: EnvironmentKey {
    static let defaultValue: LayoutDirection = .leftToRight
}

public extension EnvironmentValues {
    var fxTime: Double {
        get { self[FXTimeKey.self] }
        set { self[FXTimeKey.self] = newValue }
    }

    var layoutDirection: LayoutDirection {
        get { self[LayoutDirectionKey.self] }
        set { self[LayoutDirectionKey.self] = newValue }
    }
}

private enum SafeAreaInsetsKey: EnvironmentKey {
    static let defaultValue: EdgeInsets = .zero
}

public extension EnvironmentValues {
    var safeAreaInsets: EdgeInsets {
        get { self[SafeAreaInsetsKey.self] }
        set { self[SafeAreaInsetsKey.self] = newValue }
    }
}

private enum FXTimeKey: EnvironmentKey {
    static let defaultValue: Double = 0
}

public typealias TextMeasurer = (_ string: String, _ fontSize: Double, _ font: TextFont) -> Size

private enum TextMeasurerKey: EnvironmentKey {
    static var defaultValue: TextMeasurer {
        { string, fontSize, _ in
            Size(width: Double(string.count) * fontSize * 0.6, height: fontSize * 1.3)
        }
    }
}

public extension EnvironmentValues {
    var measureText: TextMeasurer {
        get { self[TextMeasurerKey.self] }
        set { self[TextMeasurerKey.self] = newValue }
    }
}
