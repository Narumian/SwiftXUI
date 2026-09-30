import Foundation

public enum ShaderPreviewBackground: String, CaseIterable, Codable, Sendable {
    case light, dark, neutral, checker

    public var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .neutral: return "Neutral"
        case .checker: return "Checkerboard"
        }
    }
}

public enum ShaderPreviewControlKind: String, Codable, Sendable {
    case slider, colorPicker
}

/// A generated control description. The order is the descriptor's authored order.
public struct ShaderPreviewControl: Equatable, Sendable {
    public let descriptor: ShaderParameterDescriptor
    public let kind: ShaderPreviewControlKind
    public let value: ShaderParameterValue

    public init(descriptor: ShaderParameterDescriptor, value: ShaderParameterValue) {
        self.descriptor = descriptor
        self.value = value
        self.kind = descriptor.type == .float ? .slider : .colorPicker
    }
}

/// Pure value state for a preview surface; it has no UI or renderer dependency.
public struct ShaderPreviewState: Sendable {
    public let registry: ShaderAssetRegistry
    public private(set) var selectedKey: ShaderAssetKey
    public private(set) var parameterValues: ShaderParameterValues
    public var background: ShaderPreviewBackground

    public enum Error: Swift.Error, Equatable, Sendable {
        case emptyRegistry
        case unknownAsset(ShaderAssetKey)
        case parameter(ShaderParameterValues.Error)
    }

    public init(registry: ShaderAssetRegistry,
                selectedKey: ShaderAssetKey? = nil,
                background: ShaderPreviewBackground = .checker) throws {
        guard let initial = selectedKey ?? registry.all.first?.key else { throw Error.emptyRegistry }
        guard let descriptor = registry.descriptor(for: initial) else { throw Error.unknownAsset(initial) }
        self.registry = registry
        self.selectedKey = initial
        self.parameterValues = ShaderParameterValues(descriptor: descriptor)
        self.background = background
    }

    public var descriptor: ShaderAssetDescriptor { registry.descriptor(for: selectedKey)! }

    public var controls: [ShaderPreviewControl] {
        descriptor.parameters.map { ShaderPreviewControl(descriptor: $0, value: parameterValues.values[$0.id] ?? $0.defaultValue) }
    }

    public mutating func select(_ key: ShaderAssetKey) throws {
        guard let descriptor = registry.descriptor(for: key) else { throw Error.unknownAsset(key) }
        selectedKey = key
        parameterValues = ShaderParameterValues(descriptor: descriptor)
    }

    public mutating func update(_ value: ShaderParameterValue, forParameter id: String) throws {
        do { try parameterValues.set(value, for: id, descriptor: descriptor) }
        catch let error as ShaderParameterValues.Error { throw Error.parameter(error) }
    }

    public mutating func resetParameters() { parameterValues.reset(descriptor: descriptor) }
}
