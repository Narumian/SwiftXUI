import Foundation
import XWorkspace

/// What a file is, for icons and filtering. Decided once per listing from the extension.
public enum FileCategory: UInt8, CaseIterable, Sendable {
    case folder, image, video, audio, shader, laser, project, text, other

    public static func category(forExtension ext: String) -> FileCategory {
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp": .image
        case "mp4", "mov", "m4v", "hap": .video
        case "wav", "mp3", "aif", "aiff", "m4a", "flac": .audio
        case "fs", "vs", "glsl", "metal", "wgsl", "isf", "frag", "vert": .shader
        case "ild", "ildx", "lsf": .laser
        case "trident": .project
        case "txt", "md", "json", "csv", "xml": .text
        default: .other
        }
    }
}

/// One row of a listing with everything the browser needs precomputed, so a
/// frame never touches strings: the folded name bytes drive sorting and search.
public struct BrowserItem: Sendable {
    public let entry: WorkspaceEntry
    public let category: FileCategory
    /// ASCII-case-folded UTF-8 of the display name.
    let key: ContiguousArray<UInt8>
    private let title: String?
    /// UTF-8 offset in `path` where the last component starts, and where its extension starts in `key` (-1: none).
    /// Found once while loading so drawing a cell never searches a string.
    private let nameOffset: Int32
    private let extensionOffset: Int32

    public var isDirectory: Bool { entry.kind == .directory }
    public var path: String { entry.path }
    public var name: String {
        if let title { return title }
        return String(decoding: entry.path.utf8.dropFirst(Int(nameOffset)), as: UTF8.self)
    }
    /// Up to four uppercase extension letters for the type icon.
    var badge: String {
        guard extensionOffset >= 0 else { return "" }
        let start = Int(extensionOffset) + 1
        return String(decoding: key[start..<min(key.count, start + 4)], as: UTF8.self).uppercased()
    }

    public init(entry: WorkspaceEntry, displayName: String? = nil) {
        self.entry = entry
        title = displayName
        // One pass over the path: the folded last component, and where its extension starts.
        var key = ContiguousArray<UInt8>()
        var dot = -1
        var nameStart = 0
        if let displayName {
            key = BrowserOrdering.foldedBytes(displayName)
        } else {
            let all = entry.path.utf8
            let utf8 = all.lastIndex(of: 0x2F).map { all[all.index(after: $0)...] } ?? all[...]
            nameStart = all.distance(from: all.startIndex, to: utf8.startIndex)
            key.reserveCapacity(utf8.count)
            for byte in utf8 {
                if byte == 0x2E { dot = key.count }
                key.append(byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte)
            }
        }
        self.key = key
        nameOffset = Int32(nameStart)
        extensionOffset = dot > 0 ? Int32(dot) : -1
        if entry.kind == .directory {
            category = .folder
        } else if dot > 0, dot < key.count - 1 {
            category = FileCategory.category(forExtension: String(decoding: key[(dot + 1)...], as: UTF8.self))
        } else {
            category = .other
        }
    }
}

/// Which files the browser shows. Directories always show so navigation keeps working.
public struct BrowserFilter: Sendable, Equatable {
    public var categories: Set<FileCategory>?
    public var extensions: Set<String>?

    public init(categories: Set<FileCategory>? = nil, extensions: Set<String>? = nil) {
        self.categories = categories
        self.extensions = extensions
    }

    public static let all = BrowserFilter()

    func admits(_ item: BrowserItem) -> Bool {
        if item.isDirectory { return true }
        if let categories, !categories.contains(item.category) { return false }
        if let extensions, !extensions.contains(item.entry.fileExtension) { return false }
        return true
    }
}
