import Foundation

/// A stable, provider-defined object identity. A placement should have its own ID.
public struct LiveObjectID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum LiveAccessError: Error, Equatable, Sendable {
    case invalidPath, notFound, ambiguousPath, unsupportedOperation, invalidValue
}

/// An absolute path of stable child keys, independent of display names.
public struct LivePath: Hashable, Codable, Sendable, CustomStringConvertible {
    public let components: [String]
    public static let root = try! LivePath(components: [])

    public init(components: [String]) throws {
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") }) else {
            throw LiveAccessError.invalidPath
        }
        self.components = components
    }

    public init(_ absolutePath: String) throws {
        guard absolutePath.first == "/" else { throw LiveAccessError.invalidPath }
        if absolutePath == "/" { try self.init(components: []); return }
        try self.init(components: absolutePath.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init))
    }

    public var description: String { "/" + components.joined(separator: "/") }
    public func appending(_ component: String) throws -> LivePath { try LivePath(components: components + [component]) }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Values carry their type across process boundaries; references use provider-defined IDs.
public indirect enum LiveValue: Codable, Equatable, Sendable {
    case boolean(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case reference(LiveObjectID)
    case array([LiveValue])
    case object([String: LiveValue])
    case null
}

public enum LiveValueKind: String, Codable, Sendable {
    case boolean, integer, number, string, reference, array, object
}

public struct LiveValueDescriptor: Codable, Equatable, Sendable {
    public let kind: LiveValueKind
    public let isReadable: Bool
    public let isWritable: Bool
    public let minimum: Double?
    public let maximum: Double?
    public let unit: String?
    public init(kind: LiveValueKind, isReadable: Bool = true, isWritable: Bool = false,
                minimum: Double? = nil, maximum: Double? = nil, unit: String? = nil) {
        self.kind = kind; self.isReadable = isReadable; self.isWritable = isWritable
        self.minimum = minimum; self.maximum = maximum; self.unit = unit
    }
}

public struct LiveAction: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let arguments: [String: LiveValueDescriptor]
    public let result: LiveValueDescriptor?
    public init(id: String, name: String, description: String? = nil,
                arguments: [String: LiveValueDescriptor] = [:], result: LiveValueDescriptor? = nil) {
        self.id = id; self.name = name; self.description = description
        self.arguments = arguments; self.result = result
    }
}

/// A snapshot of an exposed object; `key` is unique among its siblings.
public struct LiveObject: Codable, Equatable, Sendable, Identifiable {
    public let id: LiveObjectID
    public let key: String
    public let name: String
    /// An extensible provider-defined kind, such as composition, parameter, or group.
    public let kind: String
    public let mayHaveChildren: Bool
    public let value: LiveValueDescriptor?
    public let actions: [LiveAction]
    public init(id: LiveObjectID, key: String, name: String, kind: String,
                mayHaveChildren: Bool = false, value: LiveValueDescriptor? = nil, actions: [LiveAction] = []) {
        self.id = id; self.key = key; self.name = name; self.kind = kind
        self.mayHaveChildren = mayHaveChildren; self.value = value; self.actions = actions
    }
}

/// Host-owned live objects. Object IDs are stable within this provider; sibling keys
/// must be unique valid path components. Metadata is descriptive, not authorization.
/// Providers validate types, permissions, availability, and scheduling for every operation.
public protocol LiveRoot: Sendable {
    func root() async throws -> LiveObject
    func object(id: LiveObjectID) async throws -> LiveObject
    func children(of id: LiveObjectID) async throws -> [LiveObject]
    func read(id: LiveObjectID) async throws -> LiveValue
    func write(id: LiveObjectID, value: LiveValue) async throws
    func perform(id: LiveObjectID, action: String, arguments: [String: LiveValue]) async throws -> LiveValue?
}

public extension LiveRoot {
    /// Resolves each key against the current children; providers may instead override
    /// this behavior in a separate adapter if they need an atomic tree snapshot.
    func resolve(_ path: LivePath) async throws -> LiveObject {
        var current = try await root()
        for component in path.components {
            let matches = try await children(of: current.id).filter { $0.key == component }
            guard !matches.isEmpty else { throw LiveAccessError.notFound }
            guard matches.count == 1 else { throw LiveAccessError.ambiguousPath }
            current = matches[0]
        }
        return current
    }
    func read(id: LiveObjectID) async throws -> LiveValue { throw LiveAccessError.unsupportedOperation }
    func write(id: LiveObjectID, value: LiveValue) async throws { throw LiveAccessError.unsupportedOperation }
    func perform(id: LiveObjectID, action: String, arguments: [String: LiveValue] = [:]) async throws -> LiveValue? {
        throw LiveAccessError.unsupportedOperation
    }
}
