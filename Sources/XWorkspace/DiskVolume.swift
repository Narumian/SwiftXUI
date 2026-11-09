import Foundation

/// A directory on disk, reached through a platform access token and coordinated with document providers.
/// This is what `Workspace.register(directory:)` mounts. A host can also build one itself, for a directory
/// the process can always reach (such as a folder inside the app bundle), and mount it read-only.
public struct DiskVolume: WorkspaceVolume {
    private let access: any WorkspaceAccessProvider
    private let coordinator: any WorkspaceFileCoordinator
    private let token: Data

    public init(access: any WorkspaceAccessProvider, coordinator: any WorkspaceFileCoordinator = DirectWorkspaceFileCoordinator(), token: Data) {
        self.access = access; self.coordinator = coordinator; self.token = token
    }

    /// A directory the process can always reach, such as a folder inside the app bundle. Throws `invalidFolder`
    /// if it is not a directory.
    public init(directory: URL) throws {
        let access = LocalWorkspaceAccessProvider()
        self.init(access: access, token: try access.register(directory: directory))
        try validate()
    }

    public var isWritable: Bool { true }

    /// Throws `invalidFolder` unless the token still leads to a directory.
    public func validate() throws {
        try access.withAccess(token: token) { root in try Self.validateRoot(root) }
    }

    public func lease() throws -> WorkspaceLease {
        let lease = try access.beginAccess(token: token)
        do { try Self.validateRoot(lease.root) } catch { lease.release(); throw error }
        return lease
    }

    public func list(folderID: UUID, path: String) throws -> [WorkspaceEntry] {
        try withRoot { root in
            let directory = try Self.resolve(path, root: root, allowRoot: true)
            return try coordinator.coordinate(at: directory, writing: false) { directory in
                let prefix = path.isEmpty ? "" : path + "/"
                if DirectoryScanner.isAvailable {
                    return try DirectoryScanner.scan(directory) { name, isDirectory, size, modified in
                        WorkspaceEntry(folderID: folderID, path: prefix + name, kind: isDirectory ? .directory : .file,
                                       size: isDirectory ? nil : size, modified: modified)
                    }
                }
                return try Self.listWithFileManager(directory, folderID: folderID, prefix: prefix)
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

    /// One `stat`, so a browser can poll it and only list again when it moves. It is not coordinated with
    /// document providers: it only decides whether to look again, and a coordinated read costs about a
    /// millisecond on Apple platforms.
    public func stamp(path: String) throws -> WorkspaceStamp? {
        try withRoot { root in
            let directory = try Self.resolve(path, root: root, allowRoot: true)
            if DirectoryScanner.isAvailable {
                guard let found = DirectoryScanner.modification(of: directory.path) else { throw WorkspaceError.invalidPath }
                return WorkspaceStamp(rawValue: found.nanoseconds)
            }
            return try directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate.map(WorkspaceStamp.init(date:))
        }
    }

    public func read(path: String) throws -> Data {
        try withRoot { root in
            let url = try Self.resolve(path, root: root)
            return try coordinator.coordinate(at: url, writing: false) { url in
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw WorkspaceError.unsupportedItem }
                return try Data(contentsOf: url)
            }
        }
    }

    public func write(path: String, data: Data) throws {
        try withRoot { root in
            let url = try Self.resolve(path, root: root, allowMissingLeaf: true)
            try coordinator.coordinate(at: url, writing: true) { url in
                if FileManager.default.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile != true {
                    throw WorkspaceError.unsupportedItem
                }
                try data.write(to: url, options: .atomic)
            }
        }
    }

    /// Refuses to overwrite, and to move a directory into itself.
    public func move(path: String, toDirectory directory: String) throws -> String {
        try withRoot { root in
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

    private func withRoot<T>(_ body: (URL) throws -> T) throws -> T {
        try access.withAccess(token: token) { root in
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
