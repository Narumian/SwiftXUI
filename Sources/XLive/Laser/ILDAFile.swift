import Foundation
import simd

/// An ILDA Image Data Transfer Format file (IDTF, revision 011): the frames of formats 0, 1, 4 and 5, and the colour
/// palettes of format 2 that the indexed frames after them use.
public struct ILDAFile: Sendable {
    public struct Point: Sendable, Equatable {
        /// -1 (extreme left) to 1 (extreme right).
        public var x: Float
        /// -1 (extreme bottom) to 1 (extreme top).
        public var y: Float
        public var isBlanked: Bool
        /// 0...1; zero when the point is blanked.
        public var rgb: SIMD3<Float>
    }

    public struct Frame: Sendable {
        public var name: String
        public var number: Int
        public var points: [Point]
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notILDA, truncated(offset: Int), unknownFormat(UInt8), noFrames
        public var description: String {
            switch self {
            case .notILDA: "Not an ILDA file (no ILDA header)."
            case .truncated(let offset): "The ILDA file ends inside a section at byte \(offset)."
            case .unknownFormat(let format): "Unknown ILDA format code \(format)."
            case .noFrames: "The ILDA file has no frames."
            }
        }
    }

    public var frames: [Frame]

    /// The suggested default palette of the standard (appendix A), which "most ILDA files that do not contain a color
    /// palette, including the ILDA test pattern" use.
    public static let defaultPalette: [SIMD3<UInt8>] = {
        var colors: [SIMD3<UInt8>] = []
        for i in 0..<16 { colors.append([255, UInt8(16 * i), 0]) }                                  // 0...15 red to orange
        colors.append([255, 255, 0])                                                                // 16 yellow
        for i in 1...7 { colors.append([UInt8(256 - 32 * i), 255, 0]) }                             // 17...23
        colors.append([0, 255, 0])                                                                  // 24 green
        for blue in [36, 73, 109, 146, 182, 219, 255] { colors.append([0, 255, UInt8(blue)]) }      // 25...31 to cyan
        for green in [227, 198, 170, 142, 113, 85, 56, 28] { colors.append([0, UInt8(green), 255]) } // 32...39
        colors.append([0, 0, 255])                                                                  // 40 blue
        for i in 1...7 { colors.append([UInt8(32 * i), 0, 255]) }                                   // 41...47
        colors.append([255, 0, 255])                                                                // 48 magenta
        for i in 1...7 { colors.append([255, UInt8(32 * i), 255]) }                                 // 49...55
        colors.append([255, 255, 255])                                                              // 56 white
        for i in 1...7 { colors.append([255, UInt8(256 - 32 * i), UInt8(256 - 32 * i)]) }           // 57...63
        return colors
    }()

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        func i16(_ at: Int) -> Float { Float(Int16(bitPattern: UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1]))) / 32768 }
        guard bytes.count >= 32, bytes[0..<4].elementsEqual("ILDA".utf8) else { throw ParseError.notILDA }
        var palette = Self.defaultPalette
        var frames: [Frame] = []
        var offset = 0
        while offset + 32 <= bytes.count, bytes[offset..<offset + 4].elementsEqual("ILDA".utf8) {
            let format = bytes[offset + 7]
            let name = String(decoding: bytes[offset + 8..<offset + 16].filter { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let count = u16(offset + 24), number = u16(offset + 26)
            if count == 0 { break } // the header with no records ends the file
            let size: Int
            switch format {
            case 0: size = 8
            case 1: size = 6
            case 2: size = 3
            case 4: size = 10
            case 5: size = 8
            default: throw ParseError.unknownFormat(format)
            }
            let start = offset + 32
            guard start + count * size <= bytes.count else { throw ParseError.truncated(offset: offset) }
            if format == 2 {
                palette = (0..<count).map { SIMD3(bytes[start + 3 * $0], bytes[start + 3 * $0 + 1], bytes[start + 3 * $0 + 2]) }
            } else {
                var points: [Point] = []
                points.reserveCapacity(count)
                for index in 0..<count {
                    let at = start + index * size
                    let x = i16(at), y = i16(at + 2)
                    let status: UInt8, color: SIMD3<Float>
                    switch format {
                    case 0, 1:
                        let statusAt = at + (format == 0 ? 6 : 4)
                        status = bytes[statusAt]
                        let entry = Int(bytes[statusAt + 1])
                        let rgb = entry < palette.count ? palette[entry] : SIMD3<UInt8>(255, 255, 255)
                        color = SIMD3(Float(rgb.x), Float(rgb.y), Float(rgb.z)) / 255
                    default:
                        let statusAt = at + (format == 4 ? 6 : 4)
                        status = bytes[statusAt]
                        color = SIMD3(Float(bytes[statusAt + 3]), Float(bytes[statusAt + 2]), Float(bytes[statusAt + 1])) / 255 // stored blue, green, red
                    }
                    let blanked = status & 0x40 != 0
                    points.append(Point(x: x, y: y, isBlanked: blanked, rgb: blanked ? .zero : color))
                }
                frames.append(Frame(name: name, number: number, points: points))
            }
            offset = start + count * size
        }
        guard !frames.isEmpty else { throw ParseError.noFrames }
        self.frames = frames
    }
}

public extension ILDAFile.Frame {
    /// The frame as the points an output plays, one for one (no resampling, no padding: the file is what the pattern
    /// is). `intensity` scales the colours, 1 being the file's own.
    func laserPoints(intensity: Float) throws -> [LaserPoint] {
        let scale = min(1, max(0, intensity))
        return try points.map { point in
            let rgb = point.rgb * scale
            return try LaserPoint(xy: SIMD2(point.x, point.y), rgb: rgb, isBlanked: point.isBlanked || rgb == .zero)
        }
    }
}
