import Foundation

/// Stable, namespaced identity for a static shader asset.
public struct ShaderAssetKey: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ value: String) {
        guard Self.isValid(value) else { return nil }
        rawValue = value
    }

    public init?(rawValue: String) { self.init(rawValue) }

    public var description: String { rawValue }

    private static func isValid(_ value: String) -> Bool {
        guard value.count >= 3, value == value.lowercased(), !value.hasPrefix("."), !value.hasSuffix(".") else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isNumber || $0 == "_" || ($0 >= "a" && $0 <= "z") }
        }
    }
}

public struct ShaderColor: Equatable, Sendable, Codable {
    public let red: Float
    public let green: Float
    public let blue: Float
    public let alpha: Float

    public init(red: Float, green: Float, blue: Float, alpha: Float = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

public enum ShaderParameterValue: Equatable, Sendable, Codable {
    case float(Float)
    case color(ShaderColor)
}

public enum ShaderParameterType: String, Sendable, Codable { case float, color }

/// Renderer-neutral meaning of the fixed group-0 input texture.
///
/// The texture ABI is deliberately unchanged. This semantic only tells a
/// consumer what the RGBA sample represents; alpha-only data must not be
/// interpreted as a distance field.
public enum ShaderInputSemantic: String, CaseIterable, Sendable, Codable {
    case none
    case premultipliedColorAlpha
    case alphaMask
    /// Alpha is only a secondary mask for an analytic shape authored by the
    /// asset. It must not be treated as an arbitrary silhouette/SDF.
    case analyticShapeAlphaMask
    case normalizedSignedDistanceMask
}

/// Describes how a preview should present the shader's alpha channel.
public enum ShaderAlphaBehavior: String, CaseIterable, Sendable, Codable {
    case opaque
    case translucent
    case inputMasked
}

/// Renderer-neutral presentation hints authored alongside an asset descriptor.
public struct ShaderPreviewConfiguration: Equatable, Sendable, Codable {
    public let recommendedBackground: ShaderPreviewBackground
    public let alphaBehavior: ShaderAlphaBehavior

    public init(recommendedBackground: ShaderPreviewBackground = .checker,
                alphaBehavior: ShaderAlphaBehavior = .opaque) {
        self.recommendedBackground = recommendedBackground
        self.alphaBehavior = alphaBehavior
    }
}

/// Human-facing identity and preview guidance for a static shader asset.
public struct ShaderAssetMetadata: Equatable, Sendable, Codable {
    public let displayName: String
    public let shortDescription: String
    public let previewConfiguration: ShaderPreviewConfiguration

    public init(displayName: String, shortDescription: String,
                previewConfiguration: ShaderPreviewConfiguration = .init()) {
        self.displayName = displayName
        self.shortDescription = shortDescription
        self.previewConfiguration = previewConfiguration
    }
}

/// Explicit ABI mapping. A parameter occupies one component or one RGB slot.
public enum ShaderParameterSlot: String, CaseIterable, Hashable, Sendable, Codable {
    case slot0X, slot0Y, slot0Z, slot0W
    case slot1RGB, slot2RGB, slot3RGB
}

public struct ShaderParameterDescriptor: Equatable, Sendable, Codable {
    public let id: String
    public let displayName: String
    public let type: ShaderParameterType
    public let defaultValue: ShaderParameterValue
    public let range: ClosedRange<Float>?
    public let gpuSlot: ShaderParameterSlot

    public init(id: String, displayName: String, type: ShaderParameterType,
                defaultValue: ShaderParameterValue, range: ClosedRange<Float>? = nil,
                gpuSlot: ShaderParameterSlot) {
        self.id = id; self.displayName = displayName; self.type = type
        self.defaultValue = defaultValue; self.range = range; self.gpuSlot = gpuSlot
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidID(String), emptyDisplayName(String), duplicateSlot(ShaderParameterSlot)
        case typeMismatch(String), missingRange(String), invalidRange(String)
        case defaultOutOfRange(String), invalidColor(String)
    }

    public func validate() throws {
        guard id.isEmpty == false, id == id.lowercased(), id.allSatisfy({ $0.isNumber || $0 == "_" || ($0 >= "a" && $0 <= "z") }) else { throw ValidationError.invalidID(id) }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError.emptyDisplayName(id) }
        switch (type, defaultValue) {
        case (.float, .float(let value)):
            guard let range else { throw ValidationError.missingRange(id) }
            guard range.lowerBound < range.upperBound else { throw ValidationError.invalidRange(id) }
            guard range.contains(value) else { throw ValidationError.defaultOutOfRange(id) }
        case (.color, .color(let color)):
            guard range == nil else { throw ValidationError.typeMismatch(id) }
            guard [color.red, color.green, color.blue, color.alpha].allSatisfy({ (0...1).contains($0) }) else { throw ValidationError.invalidColor(id) }
        default: throw ValidationError.typeMismatch(id)
        }
    }
}

public struct ShaderAssetDescriptor: Equatable, Sendable, Codable {
    /// Compatibility projection retained for existing consumers. New code
    /// should use `inputSemantic` because `optionalColor` was ambiguous.
    public enum Input: String, Sendable, Codable { case none, optionalColor }
    public let key: ShaderAssetKey
    public let rootSource: String
    public let parameters: [ShaderParameterDescriptor]
    public let inputSemantic: ShaderInputSemantic
    public let metadata: ShaderAssetMetadata

    /// Deprecated compatibility projection. It intentionally collapses all
    /// non-empty input semantics to optionalColor for older clients.
    @available(*, deprecated, message: "Use inputSemantic instead")
    public var input: Input { inputSemantic == .none ? .none : .optionalColor }

    public var displayName: String { metadata.displayName }
    public var shortDescription: String { metadata.shortDescription }
    public var previewConfiguration: ShaderPreviewConfiguration { metadata.previewConfiguration }

    /// The root WGSL path (kept as an alias for consumers that use file terminology).
    public var rootFile: String { rootSource }
    public var rootPath: String { rootSource }

    public init(key: ShaderAssetKey, rootSource: String,
                parameters: [ShaderParameterDescriptor] = [], input: Input = .none,
                inputSemantic: ShaderInputSemantic? = nil,
                metadata: ShaderAssetMetadata? = nil) {
        self.key = key; self.rootSource = rootSource; self.parameters = parameters
        self.inputSemantic = inputSemantic ?? (input == .none ? .none : .premultipliedColorAlpha)
        self.metadata = metadata ?? ShaderAssetMetadata(displayName: key.rawValue,
                                                         shortDescription: "Static shader asset")
    }

    public init(key: ShaderAssetKey, rootFile: String,
                parameters: [ShaderParameterDescriptor] = [], input: Input = .none,
                inputSemantic: ShaderInputSemantic? = nil,
                metadata: ShaderAssetMetadata? = nil) {
        self.init(key: key, rootSource: rootFile, parameters: parameters, input: input,
                  inputSemantic: inputSemantic, metadata: metadata)
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case emptyRootSource, duplicateParameterID(String), duplicateSlot(ShaderParameterSlot)
        case parameter(ShaderParameterDescriptor.ValidationError)
        case emptyDisplayName, emptyShortDescription
    }

    public func validate() throws {
        guard !rootSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError.emptyRootSource }
        guard !metadata.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError.emptyDisplayName }
        guard !metadata.shortDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError.emptyShortDescription }
        var ids = Set<String>(), slots = Set<ShaderParameterSlot>()
        for parameter in parameters {
            do { try parameter.validate() } catch let error as ShaderParameterDescriptor.ValidationError { throw ValidationError.parameter(error) }
            guard ids.insert(parameter.id).inserted else { throw ValidationError.duplicateParameterID(parameter.id) }
            guard slots.insert(parameter.gpuSlot).inserted else { throw ValidationError.duplicateSlot(parameter.gpuSlot) }
        }
    }
}

public struct ShaderParameterValues: Equatable, Sendable {
    public private(set) var values: [String: ShaderParameterValue]

    /// Creates a renderer-neutral payload for a material command.
    ///
    /// Validation against an asset descriptor remains available through
    /// `set(_:for:descriptor:)`; this initializer is intentionally permissive
    /// so scene recording does not need to know which backend will consume the
    /// command later.
    public init(values: [String: ShaderParameterValue] = [:]) {
        self.values = values
    }

    public init(descriptor: ShaderAssetDescriptor) {
        values = Dictionary(uniqueKeysWithValues: descriptor.parameters.map { ($0.id, $0.defaultValue) })
    }

    public mutating func set(_ value: ShaderParameterValue, for id: String, descriptor: ShaderAssetDescriptor) throws {
        guard let parameter = descriptor.parameters.first(where: { $0.id == id }) else { throw Error.unknownParameter(id) }
        guard parameter.value(value), let value = parameter.clamped(value) else { throw Error.invalidValue(id) }
        values[id] = value
    }

    public mutating func reset(descriptor: ShaderAssetDescriptor) { values = Dictionary(uniqueKeysWithValues: descriptor.parameters.map { ($0.id, $0.defaultValue) }) }

    public enum Error: Swift.Error, Equatable, Sendable { case unknownParameter(String), invalidValue(String) }
}

private extension ShaderParameterDescriptor {
    func value(_ value: ShaderParameterValue) -> Bool {
        switch (type, value) { case (.float, .float), (.color, .color): return true; default: return false }
    }
    func clamped(_ value: ShaderParameterValue) -> ShaderParameterValue? {
        switch value {
        case .float(let number): guard let range else { return nil }; return .float(min(max(number, range.lowerBound), range.upperBound))
        case .color(let color): guard [color.red, color.green, color.blue, color.alpha].allSatisfy({ (0...1).contains($0) }) else { return nil }; return .color(color)
        }
    }
}
