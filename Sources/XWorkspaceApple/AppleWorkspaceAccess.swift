import Foundation
import XWorkspace

public enum AppleWorkspaceAccessError: Error, Equatable, Sendable {
    /// The host should ask the user to select the folder again and reconnect it.
    case staleBookmark
    case coordinationDidNotRun
}

/// Persists a user-selected directory as a security-scoped bookmark on Apple platforms.
/// The host is responsible for displaying the platform folder picker and its entitlements.
///
/// Turning a bookmark back into a URL costs hundreds of microseconds, and the file browser asks for access
/// on every tick. The URL is therefore kept after the first time, and resolved again only when an operation
/// fails the way a moved or deleted folder fails. Starting and stopping the scoped access stays per operation.
public struct AppleWorkspaceAccessProvider: WorkspaceAccessProvider {
    private let resolved = ResolvedFolders()

    public init() {}

    public func register(directory: URL) throws -> Data {
        #if os(macOS)
        return try directory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    public func withAccess<T>(token: Data, _ operation: (URL) throws -> T) throws -> T {
        if let url = resolved.url(for: token) {
            do { return try Self.scoped(url, operation) }
            catch where Self.looksLikeAMovedFolder(error) { resolved.forget(token) }   // look again, once
        }
        let url = try resolve(token)
        return try Self.scoped(url, operation)
    }

    private func resolve(_ token: Data) throws -> URL {
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: token, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: token, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        guard !stale else { throw AppleWorkspaceAccessError.staleBookmark }
        resolved.set(url, for: token)
        return url
    }

    private static func scoped<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try operation(url)
    }

    /// What a folder that was moved, renamed or deleted since the URL was resolved looks like.
    private static func looksLikeAMovedFolder(_ error: Error) -> Bool {
        if let error = error as? WorkspaceError { return error == .invalidFolder }
        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain: return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        case NSPOSIXErrorDomain: return nsError.code == Int(ENOENT) || nsError.code == Int(ENOTDIR)
        default: return false
        }
    }
}

/// The URLs bookmarks resolved to, by token.
private final class ResolvedFolders: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [Data: URL] = [:]
    func url(for token: Data) -> URL? { lock.withLock { urls[token] } }
    func set(_ url: URL, for token: Data) { lock.withLock { urls[token] = url } }
    func forget(_ token: Data) { lock.withLock { _ = urls.removeValue(forKey: token) } }
}

extension AppleWorkspaceAccessProvider {
    public func beginAccess(token: Data) throws -> WorkspaceLease {
        let url = try resolved.url(for: token) ?? resolve(token)
        let started = url.startAccessingSecurityScopedResource()
        return WorkspaceLease(root: url) { if started { url.stopAccessingSecurityScopedResource() } }
    }
}

/// Coordinates each operation with Apple document and file providers.
public struct AppleWorkspaceFileCoordinator: WorkspaceFileCoordinator {
    public init() {}

    public func coordinate<T>(at url: URL, writing: Bool, _ operation: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        var result: Result<T, Error>?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: [], error: &error) { coordinatedURL in result = Result { try operation(coordinatedURL) } }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { coordinatedURL in result = Result { try operation(coordinatedURL) } }
        }
        if let error { throw error }
        guard let result else { throw AppleWorkspaceAccessError.coordinationDidNotRun }
        return try result.get()
    }
}
