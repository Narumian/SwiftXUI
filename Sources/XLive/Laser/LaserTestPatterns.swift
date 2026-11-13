import Foundation

/// The ILDA test pattern, bundled with the app: what is shown to set a laser up (size, geometry, colours, scan speed)
/// before any show is played. Two point rates of the same pattern, as ILDA publishes them.
public enum LaserTestPatterns {
    public struct Pattern: Sendable {
        public let name: String
        let file: String
    }

    public static let all = [Pattern(name: "ILDA 30K", file: "TEST_30K"), Pattern(name: "ILDA 12K", file: "TEST_12K")]

    public enum Failure: Error, CustomStringConvertible {
        case unknown(String), missing(String)
        public var description: String {
            switch self {
            case .unknown(let name): "Unknown test pattern \(name). Known: \(LaserTestPatterns.all.map(\.name).joined(separator: ", "))"
            case .missing(let file): "The bundled test pattern file \(file).ILD is missing"
            }
        }
    }

    /// The pattern's points as an output plays them: the file's first frame, one point for one, at `intensity` of the
    /// file's own brightness.
    public static func points(named name: String, intensity: Float) throws -> [LaserPoint] {
        guard let pattern = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw Failure.unknown(name) }
        guard let url = Bundle.module.url(forResource: pattern.file, withExtension: "ILD", subdirectory: "ILDA")
                ?? Bundle.module.url(forResource: pattern.file, withExtension: "ILD") else { throw Failure.missing(pattern.file) }
        let file = try ILDAFile(data: Data(contentsOf: url))
        return try file.frames[0].laserPoints(intensity: intensity)
    }
}
