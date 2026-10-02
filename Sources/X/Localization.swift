public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case en
    case ja
}

public struct LocalizedText: Codable, Equatable, Hashable, Sendable {
    public let values: [AppLanguage: String]

    public init(_ values: [AppLanguage: String]) {
        precondition(
            Set(values.keys) == Set(AppLanguage.allCases),
            "LocalizedText requires an explicit value for every AppLanguage."
        )
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try container.decode([AppLanguage: String].self, forKey: .values)
        guard Set(values.keys) == Set(AppLanguage.allCases) else {
            throw DecodingError.dataCorruptedError(
                forKey: .values,
                in: container,
                debugDescription: "LocalizedText requires an explicit value for every AppLanguage."
            )
        }
        self.values = values
    }

    public init(en: String, ja: String) {
        self.init([.en: en, .ja: ja])
    }

    public func resolve(_ language: AppLanguage) -> String { values[language] ?? "" }

    public var isEmpty: Bool {
        AppLanguage.allCases.allSatisfy { resolve($0).isEmpty }
    }

    public func map(_ transform: (String) -> String) -> LocalizedText {
        LocalizedText(
            AppLanguage.allCases.reduce(into: [:]) { result, language in
                result[language] = transform(resolve(language))
            }
        )
    }

    public func appending(_ other: LocalizedText) -> LocalizedText {
        appending(other, separator: .empty)
    }

    public func appending(_ other: LocalizedText, separator: LocalizedText) -> LocalizedText {
        LocalizedText(
            AppLanguage.allCases.reduce(into: [:]) { result, language in
                result[language] = resolve(language) + separator.resolve(language) + other.resolve(language)
            }
        )
    }

    public static func joined(_ parts: [LocalizedText], separator: LocalizedText) -> LocalizedText {
        parts.reduce(.empty) { partial, part in
            guard !part.isEmpty else { return partial }
            guard !partial.isEmpty else { return part }
            return partial.appending(part, separator: separator)
        }
    }

    public func replacing(_ marker: String, with replacement: LocalizedText) -> LocalizedText {
        LocalizedText(
            AppLanguage.allCases.reduce(into: [:]) { result, language in
                result[language] = replace(
                    marker,
                    in: resolve(language),
                    with: replacement.resolve(language)
                )
            }
        )
    }

    public static let empty = LocalizedText(uncheckedValues: [.en: "", .ja: ""])

    private init(uncheckedValues values: [AppLanguage: String]) {
        self.values = values
    }

    private enum CodingKeys: String, CodingKey {
        case values
    }
}

private func replace(_ marker: String, in value: String, with replacement: String) -> String {
    guard !marker.isEmpty else { return value }
    var result = ""
    var index = value.startIndex
    while index < value.endIndex {
        if value[index...].hasPrefix(marker) {
            result += replacement
            index = value.index(index, offsetBy: marker.count)
        } else {
            result.append(value[index])
            index = value.index(after: index)
        }
    }
    return result
}

public extension LocalizedText {
    static func + (lhs: LocalizedText, rhs: LocalizedText) -> LocalizedText {
        lhs.appending(rhs)
    }
}


public protocol Describable: Sendable {
    var localizableName: LocalizedText { get }
    var localizableDescription: LocalizedText { get }
}
