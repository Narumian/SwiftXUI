import Foundation

/// A storage adapter must reject a write if the contents have changed since
/// `expected` was read. `nil` means that the document must not already exist.
/// Adapters are responsible for coordinating their own I/O and permissions.
public protocol DocumentStorage: Sendable {
    associatedtype Location: Sendable
    func read(from location: Location) throws -> Data
    func write(_ data: Data, to location: Location, replacing expected: Data?) throws
}

/// Converts between a document and its on-disk representation. The session's
/// internal JSON snapshots are independent of this format.
public struct DocumentCodec<Document: Codable & Sendable>: Sendable {
    public let encode: @Sendable (Document) throws -> Data
    public let decode: @Sendable (Data) throws -> Document

    public init(encode: @escaping @Sendable (Document) throws -> Data,
                decode: @escaping @Sendable (Data) throws -> Document) {
        self.encode = encode
        self.decode = decode
    }

    public static var json: Self {
        Self(encode: { value in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value)
        }, decode: { try JSONDecoder().decode(Document.self, from: $0) })
    }
}

public enum DocumentSessionError: Error, Equatable, Sendable {
    case closed
    case unsavedChanges
    case undoUnavailable
    case redoUnavailable
    case externalModification
    case editInProgress
    case noEditInProgress
}

/// Immutable metadata suitable for presenting commands and save state.
public struct DocumentStatus: Equatable, Sendable {
    public let isClosed: Bool
    public let isDirty: Bool
    public let canUndo: Bool
    public let canRedo: Bool
    public let undoName: String?
    public let redoName: String?
}

/// Owns one document and its history. The document must encode its complete
/// persistent state. Values returned to callers are decoded copies; mutation
/// only becomes part of the session through `edit`.
///
/// Storage methods are synchronous and run on this actor. Implementations
/// should avoid lengthy operations or provide their own dedicated execution
/// strategy. Platform access tokens and restoration belong to the host.
public actor DocumentSession<Document: Codable & Sendable, Storage: DocumentStorage> {
    private struct Entry: Sendable {
        let name: String
        let before: Data
        let after: Data
        let beforeID: UUID
        let afterID: UUID
    }
    private struct Group: Sendable {
        let name: String
        let before: Data
        let beforeID: UUID
    }

    private let storage: Storage
    private let codec: DocumentCodec<Document>
    private let location: Storage.Location
    private var current: Data
    private var currentID = UUID()
    private var savedID: UUID?
    private var savedData: Data?
    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []
    private var closed = false
    private var group: Group?

    private init(document: Data, location: Storage.Location, storage: Storage, codec: DocumentCodec<Document>, savedData: Data?) {
        self.current = document
        self.location = location
        self.storage = storage
        self.codec = codec
        self.savedData = savedData
        if savedData != nil { self.savedID = currentID }
    }

    /// Creates a dirty, unsaved document. The destination is not touched until save.
    public static func create(_ document: Document, at location: Storage.Location, storage: Storage, codec: DocumentCodec<Document> = .json) throws -> Self {
        try Self(document: encode(document), location: location, storage: storage, codec: codec, savedData: nil)
    }

    /// A failed read or decode leaves any existing session untouched.
    public static func open(at location: Storage.Location, storage: Storage, codec: DocumentCodec<Document> = .json) throws -> Self {
        let data = try storage.read(from: location)
        let document = try codec.decode(data)
        return try Self(document: encode(document), location: location, storage: storage, codec: codec, savedData: data)
    }

    public func document() throws -> Document {
        try requireOpen()
        return try JSONDecoder().decode(Document.self, from: current)
    }

    public func status() -> DocumentStatus {
        DocumentStatus(isClosed: closed, isDirty: !closed && savedID != currentID,
                       canUndo: !closed && group == nil && !undoEntries.isEmpty, canRedo: !closed && group == nil && !redoEntries.isEmpty,
                       undoName: closed ? nil : undoEntries.last?.name,
                       redoName: closed ? nil : redoEntries.last?.name)
    }

    /// One invocation is one atomic undo step. Throwing discards the edit.
    @discardableResult
    public func edit(_ name: String, _ change: @Sendable (inout Document) throws -> Void) throws -> Bool {
        try requireOpen()
        guard group == nil else { throw DocumentSessionError.editInProgress }
        var value = try JSONDecoder().decode(Document.self, from: current)
        try change(&value)
        let next = try Self.encode(value)
        guard next != current else { return false }
        let nextID = UUID()
        undoEntries.append(Entry(name: name, before: current, after: next, beforeID: currentID, afterID: nextID))
        redoEntries.removeAll()
        current = next
        currentID = nextID
        return true
    }

    public func undo() throws {
        try requireOpen()
        guard group == nil else { throw DocumentSessionError.editInProgress }
        guard let entry = undoEntries.popLast() else { throw DocumentSessionError.undoUnavailable }
        current = entry.before
        currentID = entry.beforeID
        redoEntries.append(entry)
    }

    public func redo() throws {
        try requireOpen()
        guard group == nil else { throw DocumentSessionError.editInProgress }
        guard let entry = redoEntries.popLast() else { throw DocumentSessionError.redoUnavailable }
        current = entry.after
        currentID = entry.afterID
        undoEntries.append(entry)
    }

    /// A failed write does not change the save point or undo history.
    public func save() throws {
        try requireOpen()
        guard group == nil else { throw DocumentSessionError.editInProgress }
        let value = try JSONDecoder().decode(Document.self, from: current)
        let data = try codec.encode(value)
        try storage.write(data, to: location, replacing: savedData)
        savedData = data
        savedID = currentID
    }

    /// Closing a dirty session requires an explicit discard decision.
    public func close(discardChanges: Bool = false) throws {
        try requireOpen()
        guard group == nil || discardChanges else { throw DocumentSessionError.editInProgress }
        guard discardChanges || savedID == currentID else { throw DocumentSessionError.unsavedChanges }
        closed = true
        undoEntries.removeAll()
        redoEntries.removeAll()
        group = nil
    }

    /// Start an interactive edit. Updates are visible immediately and are
    /// committed as one undo step, or rolled back by `cancelEditGroup`.
    public func beginEditGroup(_ name: String) throws {
        try requireOpen()
        guard group == nil else { throw DocumentSessionError.editInProgress }
        group = Group(name: name, before: current, beforeID: currentID)
    }

    public func updateEditGroup(_ change: @Sendable (inout Document) throws -> Void) throws {
        try requireOpen()
        guard let group else { throw DocumentSessionError.noEditInProgress }
        var value = try JSONDecoder().decode(Document.self, from: current)
        try change(&value)
        let next = try Self.encode(value)
        guard next != current else { return }
        current = next
        currentID = next == group.before ? group.beforeID : UUID()
    }

    public func endEditGroup() throws {
        try requireOpen()
        guard let group else { throw DocumentSessionError.noEditInProgress }
        if current != group.before {
            undoEntries.append(Entry(name: group.name, before: group.before, after: current,
                                     beforeID: group.beforeID, afterID: currentID))
            redoEntries.removeAll()
        }
        self.group = nil
    }

    public func cancelEditGroup() throws {
        try requireOpen()
        guard let group else { throw DocumentSessionError.noEditInProgress }
        current = group.before
        currentID = group.beforeID
        self.group = nil
    }

    private func requireOpen() throws {
        guard !closed else { throw DocumentSessionError.closed }
    }

    private static func encode(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }
}
