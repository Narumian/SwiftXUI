import Foundation

/// A platform adapter owns permission tokens and keeps access alive throughout `operation`.
/// Tokens are opaque to the workspace and may contain sensitive information.
public protocol WorkspaceAccessProvider: Sendable {
    func register(directory: URL) throws -> Data
    func withAccess<T>(token: Data, _ operation: (URL) throws -> T) throws -> T
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
}

public enum WorkspaceError: Error, Equatable, Sendable {
    case folderNotFound, invalidFolder, invalidPath, readOnly, unsupportedItem
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
    public var name: String { path.split(separator: "/").last.map(String.init) ?? "" }
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

    public func remove(folderID: UUID) throws { registrations.remove(at: try index(folderID)) }

    public func list(folderID: UUID, path: String = "") throws -> [WorkspaceEntry] {
        try withRoot(folderID, writing: false) { root in
            let directory = try Self.resolve(path, root: root, allowRoot: true)
            return try coordinator.coordinate(at: directory, writing: false) { directory in
                try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]).compactMap { url in
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { return nil }
                    let kind: WorkspaceEntry.Kind
                    if values.isDirectory == true { kind = .directory }
                    else if values.isRegularFile == true { kind = .file }
                    else { return nil }
                    return WorkspaceEntry(folderID: folderID, path: path.isEmpty ? url.lastPathComponent : path + "/" + url.lastPathComponent, kind: kind)
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
