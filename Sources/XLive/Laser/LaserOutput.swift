import Foundation

public struct LaserOutput: Codable, Equatable, Sendable, Identifiable {
    public enum Device: String, Codable, Sendable, CaseIterable { case unassigned, laserCube }
    public var id: UUID
    public var name: String
    public var device: Device
    public var address: String
    public var masks: LaserMaskSettings
    public init(id: UUID = UUID(), name: String, device: Device = .unassigned, address: String = "", masks: LaserMaskSettings = .init()) {
        self.id = id; self.name = name; self.device = device; self.address = address; self.masks = masks
    }
    public static func isValidIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy { $0.isASCII && $0.isNumber } && (UInt8(part) != nil)
        }
    }
}

public struct LaserOutputCollection: Codable, Equatable, Sendable {
    public var outputs: [LaserOutput]
    public init(outputs: [LaserOutput] = []) { self.outputs = outputs }
    public mutating func updateMasks(_ settings: LaserMaskSettings, for id: UUID) {
        guard let index = outputs.firstIndex(where: { $0.id == id }) else { return }
        outputs[index].masks = settings
    }
}

public enum LaserOutputStorage {
    public static let key = "trident.laser.outputs.v1"
    public static func load(defaults: UserDefaults = .standard) -> LaserOutputCollection {
        if let data = defaults.data(forKey: key), let result = try? JSONDecoder().decode(LaserOutputCollection.self, from: data) { return result }
        // Preserve masks saved by the previous single-output editor.
        if let data = defaults.data(forKey: "trident.laser.masks.default"),
           let masks = try? JSONDecoder().decode(LaserMaskSettings.self, from: data), !masks.masks.isEmpty {
            return .init(outputs: [.init(name: "Laser 01", masks: masks)])
        }
        return .init()
    }
    public static func save(_ collection: LaserOutputCollection, defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(collection), forKey: key)
    }
}
