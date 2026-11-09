import Foundation

/// The one way to point at something in a workspace: `xw://<volume>/<path>`.
///
/// The volume is a registered folder, written as its UUID or, to be typed by hand, as its name
/// (`xw://Shows/media/Logo.png`). A saved reference should use the UUID form, which survives renaming
/// and reconnecting the folder; `Workspace.resolve(_:)` turns a name into that form.
///
/// The text is parsed here and not by `URL`, which would turn a non-ASCII name into punycode and does not
/// treat a space in a host the same way everywhere. `url` is built from the percent-encoded form.
public struct WorkspaceURL: Hashable, Sendable, CustomStringConvertible {
    public enum Volume: Hashable, Sendable {
        case id(UUID)
        case name(String)
    }

    public static let scheme = "xw"

    public var volume: Volume
    /// Slash-separated and relative to the volume's root; empty for the root itself.
    public var path: String

    public init(volume: Volume, path: String = "") {
        self.volume = volume; self.path = path
    }

    public init(folderID: UUID, path: String = "") {
        self.init(volume: .id(folderID), path: path)
    }

    /// Parses `xw://<volume>/<path>`. Volume and path segments may be percent-encoded or written plainly.
    /// nil for another scheme, an empty volume, or a path with empty, `.` or `..` segments.
    public init?(_ text: String) {
        let prefix = Self.scheme + "://"
        guard text.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        let split = rest.firstIndex(of: "/")
        let volumeText = split.map { rest[..<$0] } ?? rest
        let pathText = split.map { rest[rest.index(after: $0)...] } ?? ""
        guard !volumeText.isEmpty, let volumeName = Self.decode(volumeText) else { return nil }

        var segments = pathText.split(separator: "/", omittingEmptySubsequences: false)
        if segments.last?.isEmpty == true { segments.removeLast() }   // a trailing slash names a directory
        var decoded: [String] = []
        for segment in segments {
            guard let value = Self.decode(segment), !value.isEmpty, value != ".", value != ".." else { return nil }
            decoded.append(value)
        }
        volume = UUID(uuidString: volumeName).map(Volume.id) ?? .name(volumeName)
        path = decoded.joined(separator: "/")
    }

    public init?(url: URL) { self.init(url.absoluteString) }

    public var description: String {
        let volumeText: String
        switch volume {
        case .id(let id): volumeText = id.uuidString
        case .name(let name): volumeText = Self.encode(name)
        }
        let pathText = path.split(separator: "/", omittingEmptySubsequences: true).map { Self.encode(String($0)) }.joined(separator: "/")
        return Self.scheme + "://" + volumeText + (pathText.isEmpty ? "" : "/" + pathText)
    }

    public var url: URL { URL(string: description) ?? URL(fileURLWithPath: "/") }

    /// The folder this points into, when it is written with the UUID.
    public var folderID: UUID? {
        if case .id(let id) = volume { return id }
        return nil
    }

    // MARK: Percent-encoding

    private static let allowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "-._~!$&'()*+,;=:@")
        return set
    }()

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// nil when the percent-encoding is broken or the text would add a `/` or a NUL.
    private static func decode(_ text: Substring) -> String? {
        guard let value = String(text).removingPercentEncoding, !value.contains("/"), !value.contains("\0") else { return nil }
        return value
    }
}

extension WorkspaceURL: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = WorkspaceURL(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a workspace URL: \(text)"))
        }
        self = value
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public extension WorkspaceEntry {
    /// The stable address of this entry (the folder's UUID form).
    var url: WorkspaceURL { WorkspaceURL(folderID: folderID, path: path) }
}

public extension Workspace {
    func read(_ url: WorkspaceURL) throws -> Data {
        let resolved = try resolve(url)
        guard let id = resolved.folderID else { throw WorkspaceError.folderNotFound }
        return try read(folderID: id, path: resolved.path)
    }
}
