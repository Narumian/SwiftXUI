//
//  Aox.swift
//  SwiftX
//

/// A type-erased `Codable` box with an explicit type discriminator.
@propertyWrapper
public struct Aox<Catalog: AnyCodableCatalog>: Codable {
    private enum CodingKeys: String, CodingKey {
        case typeID
        case value
    }

    public enum AoxError: Error, Sendable {
        case unknownTypeID(String)
        case missingValue(String)
    }

    public var wrappedValue: any AnyCodable

    public init(wrappedValue: any AnyCodable) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeID = try container.decode(String.self, forKey: .typeID)

        guard let type = Catalog.registry.first(where: { $0.typeID == typeID }) else {
            throw AoxError.unknownTypeID(typeID)
        }

        guard container.contains(.value) else {
            throw AoxError.missingValue(typeID)
        }

        let valueDecoder = try container.superDecoder(forKey: .value)
        self.wrappedValue = try type.init(from: valueDecoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let concreteType = type(of: wrappedValue)

        try container.encode(concreteType.typeID, forKey: .typeID)

        let valueEncoder = container.superEncoder(forKey: .value)
        try wrappedValue.encode(to: valueEncoder)
    }
}
