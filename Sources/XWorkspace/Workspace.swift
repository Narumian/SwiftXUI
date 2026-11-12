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
    /// A URL named a folder by a name that more than one registered folder has.
    case ambiguousName
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

/// A volume the host provides, under a fixed `id` so that references to it stay valid across launches.
/// Its name is how a URL reaches it (`xw://bundle/…`), and it wins over a registered folder of the same name.
public struct WorkspaceMount: Sendable {
    public var id: UUID
    public var name: String
    public var volume: any WorkspaceVolume
    public var readOnly: Bool
    public init(id: UUID, name: String, volume: any WorkspaceVolume, readOnly: Bool = false) {
        self.id = id; self.name = name; self.volume = volume; self.readOnly = readOnly
    }
}

/// One workspace: a set of folders, each backed by a `WorkspaceVolume`. Folders the user registers are
/// directories on disk (`DiskVolume`) and are saved as `WorkspaceRegistration`s; a host can also mount
/// volumes of its own, which are not saved and come back only when the host mounts them again.
/// Persistence belongs to the host.
public actor Workspace {
    private struct Mount {
        var folder: WorkspaceFolder
        var volume: any WorkspaceVolume
        /// The access token of a registered directory; nil for a volume the host mounted.
        var token: Data?
        /// Mounted by the host, so a URL can name it without being ambiguous.
        var isProvided: Bool
    }

    private let access: any WorkspaceAccessProvider
    private let coordinator: any WorkspaceFileCoordinator
    private var mounts: [Mount]

    /// `provided` volumes come first in `folders()`, ahead of the registered directories.
    public init(access: any WorkspaceAccessProvider, coordinator: any WorkspaceFileCoordinator = DirectWorkspaceFileCoordinator(),
                registrations: [WorkspaceRegistration] = [], provided: [WorkspaceMount] = []) throws {
        let ids = registrations.map(\.folder.id) + provided.map(\.id)
        guard Set(ids).count == ids.count, Set(provided.map(\.name)).count == provided.count else { throw WorkspaceError.invalidFolder }
        self.access = access; self.coordinator = coordinator
        mounts = provided.map(Self.mount(for:)) + registrations.map {
            Mount(folder: $0.folder, volume: DiskVolume(access: access, coordinator: coordinator, token: $0.accessToken), token: $0.accessToken, isProvided: false)
        }
    }

    private static func mount(for provided: WorkspaceMount) -> Mount {
        Mount(folder: WorkspaceFolder(id: provided.id, name: provided.name, isReadOnly: provided.readOnly || !provided.volume.isWritable),
              volume: provided.volume, token: nil, isProvided: true)
    }

    public func folders() -> [WorkspaceFolder] { mounts.map(\.folder) }
    /// The registered directories, for the host to save. Mounted volumes are not part of it.
    public func snapshot() -> [WorkspaceRegistration] {
        mounts.compactMap { mount in mount.token.map { WorkspaceRegistration(folder: mount.folder, accessToken: $0) } }
    }

    @discardableResult
    public func register(directory: URL, name: String? = nil, readOnly: Bool = false) throws -> WorkspaceFolder {
        let token = try access.register(directory: directory)
        let volume = DiskVolume(access: access, coordinator: coordinator, token: token)
        try volume.validate()
        let folder = WorkspaceFolder(name: name ?? directory.lastPathComponent, isReadOnly: readOnly)
        mounts.append(Mount(folder: folder, volume: volume, token: token, isProvided: false))
        return folder
    }

    /// Adds a volume that the host provides, under a fixed `id` so that references to it stay valid across launches.
    @discardableResult
    public func mount(_ volume: any WorkspaceVolume, id: UUID = UUID(), name: String, readOnly: Bool = false) throws -> WorkspaceFolder {
        guard !mounts.contains(where: { $0.folder.id == id || ($0.isProvided && $0.folder.name == name) }) else { throw WorkspaceError.invalidFolder }
        let mount = Self.mount(for: WorkspaceMount(id: id, name: name, volume: volume, readOnly: readOnly))
        mounts.append(mount)
        return mount.folder
    }

    /// Turns a URL written with a folder name into the UUID form that is safe to save.
    /// A volume the host mounted wins over a registered folder of the same name. Otherwise a name matches
    /// exactly first, then ignoring case; a name shared by several folders is ambiguous.
    public func resolve(_ url: WorkspaceURL) throws -> WorkspaceURL {
        switch url.volume {
        case .id(let id):
            _ = try index(id)
            return url
        case .name(let name):
            let tiers: [[Mount]] = [
                mounts.filter { $0.isProvided && $0.folder.name == name },
                mounts.filter { $0.folder.name == name },
                mounts.filter { $0.folder.name.caseInsensitiveCompare(name) == .orderedSame },
            ]
            guard let matches = tiers.first(where: { !$0.isEmpty }) else { throw WorkspaceError.folderNotFound }
            guard matches.count == 1 else { throw WorkspaceError.ambiguousName }
            return WorkspaceURL(folderID: matches[0].folder.id, path: url.path)
        }
    }

    /// Points a registered directory at a new place. A mounted volume has no directory to change.
    public func reconnect(folderID: UUID, directory: URL) throws {
        let index = try index(folderID)
        guard mounts[index].token != nil else { throw WorkspaceError.unsupportedItem }
        let token = try access.register(directory: directory)
        let volume = DiskVolume(access: access, coordinator: coordinator, token: token)
        try volume.validate()
        mounts[index].token = token
        mounts[index].volume = volume
    }

    /// Keeps a registered folder accessible until the lease is released.
    public func lease(folderID: UUID) throws -> WorkspaceLease {
        try mounts[try index(folderID)].volume.lease()
    }

    public func remove(folderID: UUID) throws { mounts.remove(at: try index(folderID)) }

    /// Lists a directory. Pass `sorted: false` when the caller orders the entries itself.
    public func list(folderID: UUID, path: String = "", sorted: Bool = true) throws -> [WorkspaceEntry] {
        let entries = try volume(folderID, writing: false).list(folderID: folderID, path: path)
        return sorted ? entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : entries
    }

    /// A cheap token that changes when the direct contents of a directory change
    /// (entries added, removed or renamed). A browser can poll it and only list again when it moves.
    public func directoryStamp(folderID: UUID, path: String = "") throws -> WorkspaceStamp? {
        try volume(folderID, writing: false).stamp(path: path)
    }

    /// A cheap modification token for one selected file. Disk volumes answer with one metadata lookup;
    /// other volumes may return nil when they cannot provide a stable token.
    public func fileStamp(folderID: UUID, path: String) throws -> WorkspaceStamp? {
        try volume(folderID, writing: false).stamp(path: path)
    }

    public func read(folderID: UUID, path: String) throws -> Data {
        try volume(folderID, writing: false).read(path: path)
    }

    /// Writes an existing file or creates a file in an existing directory.
    public func write(folderID: UUID, path: String, data: Data) throws {
        try volume(folderID, writing: true).write(path: path, data: data)
    }

    /// Moves a file or directory into another directory of the same folder, keeping its name. Returns the new path.
    /// Refuses to overwrite, and to move a directory into itself.
    @discardableResult
    public func move(folderID: UUID, path: String, toDirectory directory: String) throws -> String {
        try volume(folderID, writing: true).move(path: path, toDirectory: directory)
    }

    private func index(_ id: UUID) throws -> Int {
        guard let index = mounts.firstIndex(where: { $0.folder.id == id }) else { throw WorkspaceError.folderNotFound }
        return index
    }
    private func volume(_ id: UUID, writing: Bool) throws -> any WorkspaceVolume {
        let mount = mounts[try index(id)]
        if writing && mount.folder.isReadOnly { throw WorkspaceError.readOnly }
        return mount.volume
    }
}
