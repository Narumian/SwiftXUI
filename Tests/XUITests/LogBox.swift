import Foundation

/// Collects values from `@Sendable` callbacks in a test, which cannot mutate a local `var`.
final class LogBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) { lock.withLock { storage.append(value) } }

    var values: [Value] { lock.withLock { storage } }
    var count: Int { values.count }
    var isEmpty: Bool { values.isEmpty }
    subscript(index: Int) -> Value { values[index] }
}
