import Foundation
import XDocument

public enum AppleDocumentProjectError: LocalizedError {
    case staleBookmark
    public var errorDescription: String? {
        "The previous project location is no longer accessible. Select its folder again."
    }
}

/// Apple-specific folder access and bookmark persistence for XDocument.
@MainActor
public final class AppleDocumentProjectEnvironment: DocumentProjectEnvironment {
    private let defaults: UserDefaults
    private let directory: String
    private let bookmarkKey: String
    private let pageKey: String
    private let readPage: (UserDefaults, String) -> String
    private let writePage: (UserDefaults, String, String) -> Void

    public init(directory: String, bookmarkKey: String, pageKey: String, defaults: UserDefaults = .standard,
                readPage: @escaping (UserDefaults, String) -> String = { $0.string(forKey: $1) ?? "" },
                writePage: @escaping (UserDefaults, String, String) -> Void = { $0.set($2, forKey: $1) }) {
        self.directory = directory
        self.bookmarkKey = bookmarkKey
        self.pageKey = pageKey
        self.defaults = defaults
        self.readPage = readPage
        self.writePage = writePage
    }

    public func defaultFolder() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = base.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func restoredFolder() throws -> URL? {
        guard let bookmark = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        guard !stale else { throw AppleDocumentProjectError.staleBookmark }
        return url
    }

    public func acquire(folder: URL) throws -> any DocumentFolderAccess { FolderAccess(folder) }

    public func remember(folder: URL) throws {
        #if os(macOS)
        let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        defaults.set(bookmark, forKey: bookmarkKey)
    }

    public var restoredPage: String {
        get { readPage(defaults, pageKey) }
        set { writePage(defaults, pageKey, newValue) }
    }
}

@MainActor
private final class FolderAccess: DocumentFolderAccess {
    private let url: URL
    private var active: Bool
    init(_ url: URL) { self.url = url; active = url.startAccessingSecurityScopedResource() }
    func releaseAccess() { if active { url.stopAccessingSecurityScopedResource(); active = false } }
}
