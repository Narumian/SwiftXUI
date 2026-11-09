import Foundation
import XUI

/// Which file extensions belong to which `FileCategory`, and what colour each category is drawn in.
/// `standard` knows the built-in categories; a host adds its own, each with the extensions that mean it:
///
///     let types = FileTypes.standard.adding(.geometry, color: …, extensions: ["geometry"])
public struct FileTypes: Sendable {
    private var custom: [String: FileCategory] = [:]
    private var colors: [FileCategory: XColorValue] = [:]

    public static let standard = FileTypes()

    public init() {}

    /// A copy that also maps `extensions` (lowercase, without the dot) to `category` and draws it in `color`.
    /// An extension given here wins over a built-in one.
    public func adding(_ category: FileCategory, color: XColorValue, extensions: [String]) -> FileTypes {
        var copy = self
        copy.colors[category] = color
        for ext in extensions { copy.custom[ext] = category }
        return copy
    }

    /// Lowercase extension without the dot.
    public func category(forExtension ext: String) -> FileCategory {
        if !custom.isEmpty, let found = custom[ext] { return found }
        return FileCategory.builtIn(forExtension: ext)
    }

    public func color(for category: FileCategory) -> XColorValue {
        colors[category] ?? Palette.color(category)
    }
}
