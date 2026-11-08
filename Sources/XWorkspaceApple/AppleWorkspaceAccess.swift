import Foundation
import XWorkspace

public enum AppleWorkspaceAccessError: Error, Equatable, Sendable {
    /// The host should ask the user to select the folder again and reconnect it.
    case staleBookmark
    case coordinationDidNotRun
}

/// Persists a user-selected directory as a security-scoped bookmark on Apple platforms.
/// The host is responsible for displaying the platform folder picker and its entitlements.
public struct AppleWorkspaceAccessProvider: WorkspaceAccessProvider {
    public init() {}

    public func register(directory: URL) throws -> Data {
        #if os(macOS)
        return try directory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    public func withAccess<T>(token: Data, _ operation: (URL) throws -> T) throws -> T {
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: token, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: token, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        guard !stale else { throw AppleWorkspaceAccessError.staleBookmark }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try operation(url)
    }
}

extension AppleWorkspaceAccessProvider {
    public func beginAccess(token: Data) throws -> WorkspaceLease {
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: token, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: token, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        guard !stale else { throw AppleWorkspaceAccessError.staleBookmark }
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
