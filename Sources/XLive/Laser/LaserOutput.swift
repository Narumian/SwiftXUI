import Foundation

public struct LaserOutput: Codable, Equatable, Sendable, Identifiable {
    public enum Device: String, Codable, Sendable, CaseIterable { case unassigned, laserCube }
    public var id: UUID
    public var name: String
    public var device: Device
    public var address: String
    public var masks: LaserMaskSettings
    public var scanner: LaserScannerProfile
    public init(id: UUID = UUID(), name: String, device: Device = .unassigned, address: String = "", masks: LaserMaskSettings = .init(), scanner: LaserScannerProfile = .init()) {
        self.id = id; self.name = name; self.device = device; self.address = address; self.masks = masks; self.scanner = scanner
    }
    private enum CodingKeys: String, CodingKey { case id, name, device, address, masks, scanner }
    /// Outputs saved before the scanner profile existed have no `scanner` key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        device = try c.decode(Device.self, forKey: .device)
        address = try c.decode(String.self, forKey: .address)
        masks = try c.decode(LaserMaskSettings.self, forKey: .masks)
        scanner = try c.decodeIfPresent(LaserScannerProfile.self, forKey: .scanner) ?? .init()
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
