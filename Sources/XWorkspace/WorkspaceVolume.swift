import Foundation

/// Tells whether the direct contents of a directory changed since the last time it was asked.
/// Only equality means anything. A disk volume derives it from the modification time; a volume that
/// is not on disk can count its own changes.
public struct WorkspaceStamp: Hashable, Sendable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public init(date: Date) { self.init(rawValue: Int64((date.timeIntervalSince1970 * 1e9).rounded())) }
}

/// What stands behind a folder of a `Workspace`: a directory on disk, or anything that can list, read and
/// (maybe) change a tree of files addressed by relative paths such as `media/Logo.png`.
///
/// Paths are slash-separated and relative to the volume's root; the empty path is the root. A volume
/// validates the paths it is given and throws `WorkspaceError.invalidPath` for the ones it cannot serve.
/// Calls are synchronous, as the workspace has always been: a listing is one pass, and a volume that
/// cannot answer quickly has no place here yet.
public protocol WorkspaceVolume: Sendable {
    /// False when `write` and `move` are refused. The workspace also honours a folder's own read-only flag.
    var isWritable: Bool { get }

    /// The direct contents of a directory. Entries carry `folderID` and the full path from the root, and are
    /// not sorted. Anything that is not a file or a directory is left out.
    func list(folderID: UUID, path: String) throws -> [WorkspaceEntry]
    func stamp(path: String) throws -> WorkspaceStamp?
    func read(path: String) throws -> Data
    /// Writes an existing file or creates a file in an existing directory.
    func write(path: String, data: Data) throws
    /// Moves a file or directory into another directory of the volume, keeping its name. Returns the new path.
    func move(path: String, toDirectory directory: String) throws -> String
    /// Access to the root that outlives a closure, for a reader that needs real file URLs.
    /// Volumes that are not backed by a directory throw `unsupportedItem`.
    func lease() throws -> WorkspaceLease
}

public extension WorkspaceVolume {
    var isWritable: Bool { false }
    func write(path: String, data: Data) throws { throw WorkspaceError.readOnly }
    func move(path: String, toDirectory directory: String) throws -> String { throw WorkspaceError.readOnly }
    func lease() throws -> WorkspaceLease { throw WorkspaceError.unsupportedItem }
}
