import Foundation

/// Immutable lookup of validated shader metadata. It deliberately owns no GPU handles.
public struct ShaderAssetRegistry: Sendable {
    private let assets: [ShaderAssetKey: ShaderAssetDescriptor]

    public enum Error: Swift.Error, Equatable, Sendable { case duplicateKey(ShaderAssetKey), invalidDescriptor(ShaderAssetDescriptor.ValidationError) }

    public init(_ descriptors: [ShaderAssetDescriptor]) throws {
        var result: [ShaderAssetKey: ShaderAssetDescriptor] = [:]
        for descriptor in descriptors {
            do { try descriptor.validate() } catch let error as ShaderAssetDescriptor.ValidationError { throw Error.invalidDescriptor(error) }
            guard result.updateValue(descriptor, forKey: descriptor.key) == nil else { throw Error.duplicateKey(descriptor.key) }
        }
        assets = result
    }

    public var all: [ShaderAssetDescriptor] { assets.values.sorted { $0.key.rawValue < $1.key.rawValue } }
    public func descriptor(for key: ShaderAssetKey) -> ShaderAssetDescriptor? { assets[key] }
    public subscript(key: ShaderAssetKey) -> ShaderAssetDescriptor? { assets[key] }
}
