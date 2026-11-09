import Foundation

/// A platform adapter owns permission tokens and keeps access alive throughout `operation`.
/// Tokens are opaque to the workspace and may contain sensitive information.
public protocol WorkspaceAccessProvider: Sendable {
    func register(directory: URL) throws -> Data
    func withAccess<T>(token: Data, _ operation: (URL) throws -> T) throws -> T
    /// Opens access that outlives a closure. Providers without a long-lived form throw `unsupportedItem`.
    func beginAccess(token: Data) throws -> WorkspaceLease
}

public extension WorkspaceAccessProvider {
    func beginAccess(token: Data) throws -> WorkspaceLease { throw WorkspaceError.unsupportedItem }
}

/// Access that stays open until released: for a project that keeps reading and saving
/// under a folder for as long as it is open.
public final class WorkspaceLease: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private var releaseAction: (() -> Void)?

    public init(root: URL, release: @escaping () -> Void) {
        self.root = root
        releaseAction = release
    }

    /// The URL of a path inside the leased folder. Valid until `release()`.
    public func url(for path: String) -> URL {
        path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: true)
    }

    public func release() {
        let action = lock.withLock { () -> (() -> Void)? in defer { releaseAction = nil }; return releaseAction }
        action?()
    }

    deinit { release() }
}

/// Platform adapters can coordinate filesystem operations with document providers.
public protocol WorkspaceFileCoordinator: Sendable {
    func coordinate<T>(at url: URL, writing: Bool, _ operation: (URL) throws -> T) throws -> T
}

public struct DirectWorkspaceFileCoordinator: WorkspaceFileCoordinator {
    public init() {}
    public func coordinate<T>(at url: URL, writing: Bool, _ operation: (URL) throws -> T) throws -> T {
        try operation(url)
    }
}

/// For environments where the process already has access. This does not grant OS permissions.
public struct LocalWorkspaceAccessProvider: WorkspaceAccessProvider {
    public init() {}
    public func register(directory: URL) throws -> Data {
        guard directory.isFileURL else { throw WorkspaceError.invalidFolder }
        return Data(directory.standardizedFileURL.path.utf8)
    }
    public func withAccess<T>(token: Data, _ operation: (URL) throws -> T) throws -> T {
        guard let path = String(data: token, encoding: .utf8), path.hasPrefix("/") else {
            throw WorkspaceError.invalidFolder
        }
        return try operation(URL(fileURLWithPath: path, isDirectory: true))
    }
    public func beginAccess(token: Data) throws -> WorkspaceLease {
        try withAccess(token: token) { WorkspaceLease(root: $0, release: {}) }
    }
}

public enum WorkspaceError: Error, Equatable, Sendable {
    case folderNotFound, invalidFolder, invalidPath, readOnly, unsupportedItem
    /// Something with that name is already there.
    case alreadyExists
}

public struct WorkspaceFolder: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var isReadOnly: Bool
    public init(id: UUID = UUID(), name: String, isReadOnly: Bool = false) {
        self.id = id; self.name = name; self.isReadOnly = isReadOnly
    }
}

/// Persist this in app-private storage; access tokens are supplied by the platform adapter.
public struct WorkspaceRegistration: Codable, Sendable {
    public var folder: WorkspaceFolder
    public var accessToken: Data
    public init(folder: WorkspaceFolder, accessToken: Data) {
        self.folder = folder; self.accessToken = accessToken
    }
}

public struct WorkspaceEntry: Equatable, Sendable {
    public enum Kind: Sendable { case file, directory }
    public let folderID: UUID
    public let path: String
    public let kind: Kind
    /// Byte size of a file; nil for directories and when the provider does not say.
    public let size: Int64?
    public let modified: Date?
    public var name: String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
    /// Lowercased extension without the dot; empty for directories and extensionless files.
    public var fileExtension: String {
        guard kind == .file, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    public init(folderID: UUID, path: String, kind: Kind, size: Int64? = nil, modified: Date? = nil) {
        self.folderID = folderID; self.path = path; self.kind = kind; self.size = size; self.modified = modified
    }
}

/// One workspace with multiple explicitly registered roots. Persistence belongs to its host.
public actor Workspace {
    private let access: any WorkspaceAccessProvider
    private let coordinator: any WorkspaceFileCoordinator
    private var registrations: [WorkspaceRegistration]

    public init(access: any WorkspaceAccessProvider, coordinator: any WorkspaceFileCoordinator = DirectWorkspaceFileCoordinator(), registrations: [WorkspaceRegistration] = []) throws {
        guard Set(registrations.map(\.folder.id)).count == registrations.count else { throw WorkspaceError.invalidFolder }
        self.access = access; self.coordinator = coordinator; self.registrations = registrations
    }

    public func folders() -> [WorkspaceFolder] { registrations.map(\.folder) }
    public func snapshot() -> [WorkspaceRegistration] { registrations }

    @discardableResult
    public func register(directory: URL, name: String? = nil, readOnly: Bool = false) throws -> WorkspaceFolder {
        let token = try access.register(directory: directory)
        try access.withAccess(token: token) { root in try Self.validateRoot(root) }
        let folder = WorkspaceFolder(name: name ?? directory.lastPathComponent, isReadOnly: readOnly)
        registrations.append(WorkspaceRegistration(folder: folder, accessToken: token))
        return folder
    }

    public func reconnect(folderID: UUID, directory: URL) throws {
        let index = try index(folderID)
        let token = try access.register(directory: directory)
        try access.withAccess(token: token) { root in try Self.validateRoot(root) }
        registrations[index].accessToken = token
    }

    /// Keeps a registered folder accessible until the lease is released.
    public func lease(folderID: UUID) throws -> WorkspaceLease {
        let registration = registrations[try index(folderID)]
        let lease = try access.beginAccess(token: registration.accessToken)
        do { try Self.validateRoot(lease.root) } catch { lease.release(); throw error }
        return lease
    }

    public func remove(folderID: UUID) throws { registrations.remove(at: try index(folderID)) }

    /// Lists a directory. Pass `sorted: false` when the caller orders the entries itself.
    public func list(folderID: UUID, path: String = "", sorted: Bool = true) throws -> [WorkspaceEntry] {
        try withRoot(folderID, writing: false) { root in
            let directory = try Self.resolve(path, root: root, allowRoot: true)
            return try coordinator.coordinate(at: directory, writing: false) { directory in
                let prefix = path.isEmpty ? "" : path + "/"
                var entries: [WorkspaceEntry]
                if DirectoryScanner.isAvailable {
                    entries = try DirectoryScanner.scan(directory).map {
                        WorkspaceEntry(folderID: folderID, path: prefix + $0.name, kind: $0.isDirectory ? .directory : .file,
                                       size: $0.isDirectory ? nil : $0.size, modified: $0.modified)
                    }
                } else {
                    entries = try Self.listWithFileManager(directory, folderID: folderID, prefix: prefix)
                }
                return sorted ? entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : entries
            }
        }
    }

    private static func listWithFileManager(_ directory: URL, folderID: UUID, prefix: String) throws -> [WorkspaceEntry] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: listingKeys).compactMap { url in
            let values = try url.resourceValues(forKeys: listingKeySet)
            guard values.isSymbolicLink != true else { return nil }
            let kind: WorkspaceEntry.Kind
            if values.isDirectory == true { kind = .directory }
            else if values.isRegularFile == true { kind = .file }
            else { return nil }
            return WorkspaceEntry(folderID: folderID, path: prefix + url.lastPathComponent, kind: kind,
                                  size: kind == .file ? values.fileSize.map(Int64.init) : nil, modified: values.contentModificationDate)
        }
    }

    /// A cheap token that changes when the direct contents of a directory change
    /// (entries added, removed or renamed). One `stat`, so a browser can poll it
    /// and only list again when it moves.
    public func directoryStamp(folderID: UUID, path: String = "") throws -> Date? {
        try withRoot(folderID, writing: false) { root in
            let directory = try Self.resolve(path, root: root, allowRoot: true)
            return try coordinator.coordinate(at: directory, writing: false) { directory in
                try directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
        }
    }

    public func read(folderID: UUID, path: String) throws -> Data {
        try withRoot(folderID, writing: false) { root in
            let url = try Self.resolve(path, root: root)
            return try coordinator.coordinate(at: url, writing: false) { url in
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw WorkspaceError.unsupportedItem }
                return try Data(contentsOf: url)
            }
        }
    }

    /// Writes an existing file or creates a file in an existing directory.
    public func write(folderID: UUID, path: String, data: Data) throws {
        try withRoot(folderID, writing: true) { root in
            let url = try Self.resolve(path, root: root, allowMissingLeaf: true)
            try coordinator.coordinate(at: url, writing: true) { url in
                if FileManager.default.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile != true {
                    throw WorkspaceError.unsupportedItem
                }
                try data.write(to: url, options: .atomic)
            }
        }
    }

    /// Moves a file or directory into another directory of the same folder, keeping its name. Returns the new path.
    /// Refuses to overwrite, and to move a directory into itself.
    @discardableResult
    public func move(folderID: UUID, path: String, toDirectory directory: String) throws -> String {
        try withRoot(folderID, writing: true) { root in
            if directory == path || directory.hasPrefix(path + "/") { throw WorkspaceError.invalidPath }
            let source = try Self.resolve(path, root: root)
            let destination = try Self.resolve(directory, root: root, allowRoot: true)
            let name = source.lastPathComponent
            let target = destination.appendingPathComponent(name)
            guard try destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw WorkspaceError.unsupportedItem }
            guard !FileManager.default.fileExists(atPath: target.path) else { throw WorkspaceError.alreadyExists }
            try coordinator.coordinate(at: source, writing: true) { source in
                try FileManager.default.moveItem(at: source, to: target)
            }
            return directory.isEmpty ? name : directory + "/" + name
        }
    }

    private static let listingKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
    private static let listingKeySet = Set(listingKeys)

    private func index(_ id: UUID) throws -> Int {
        guard let index = registrations.firstIndex(where: { $0.folder.id == id }) else { throw WorkspaceError.folderNotFound }
        return index
    }
    private func withRoot<T>(_ id: UUID, writing: Bool, _ body: (URL) throws -> T) throws -> T {
        let registration = registrations[try index(id)]
        if writing && registration.folder.isReadOnly { throw WorkspaceError.readOnly }
        return try access.withAccess(token: registration.accessToken) { root in
            try Self.validateRoot(root)
            return try body(root)
        }
    }
    private static func validateRoot(_ root: URL) throws {
        guard root.isFileURL, try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw WorkspaceError.invalidFolder }
    }
    private static func resolve(_ path: String, root: URL, allowRoot: Bool = false, allowMissingLeaf: Bool = false) throws -> URL {
        if path.isEmpty && allowRoot { return root }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw WorkspaceError.invalidPath }
        var url = root
        for (index, part) in parts.enumerated() {
            url.appendPathComponent(String(part))
            do {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw WorkspaceError.invalidPath }
            } catch let error as NSError {
                guard allowMissingLeaf && index == parts.count - 1 && error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError else { throw error }
            }
        }
        return url
    }
}
