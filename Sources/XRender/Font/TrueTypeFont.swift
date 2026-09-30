import Foundation

/// A parsed TrueType (`glyf`) font. Pure Swift on purpose: the glyph pipeline
/// must render identically on every platform, so nothing here touches
/// CoreText / DirectWrite / FreeType.
///
/// Scope: `head`, `maxp`, `hhea`, `hmtx`, `cmap` (formats 4 and 12), `loca`,
/// `glyf` (simple + composite) and `OS/2` cap height. No hinting, no kerning,
/// no CFF, no variation (`gvar`) — a variable font is read at its default
/// instance. Every read is bounds-checked, so a truncated file yields empty
/// glyphs rather than a crash.
public final class TrueTypeFont: @unchecked Sendable {
    public struct Point: Sendable, Equatable {
        public var x: Float
        public var y: Float
        public var onCurve: Bool
        public init(x: Float, y: Float, onCurve: Bool) { self.x = x; self.y = y; self.onCurve = onCurve }
    }

    public let unitsPerEm: Int
    public let numGlyphs: Int
    public let ascender: Int
    public let descender: Int      // negative below the baseline, as in `hhea`
    public let lineGap: Int
    /// `OS/2.sCapHeight` when present; otherwise the top of the glyph "H".
    public private(set) var capHeight: Int = 0

    private let bytes: [UInt8]
    private var tables: [String: (offset: Int, length: Int)] = [:]
    private let longLoca: Bool
    private let numHMetrics: Int
    private var cmapOffsets: [(format: Int, offset: Int)] = []

    public convenience init?(data: Data) { self.init(bytes: [UInt8](data)) }

    public init?(bytes: [UInt8]) {
        self.bytes = bytes
        guard bytes.count > 12 else { return nil }
        let tag = Self.u32(bytes, 0)
        // 0x00010000 = TrueType, 'true' = Apple TrueType. 'OTTO' (CFF) is out of scope.
        guard tag == 0x0001_0000 || tag == 0x7472_7565 else { return nil }
        let count = Self.u16(bytes, 4)
        var found: [String: (Int, Int)] = [:]
        for i in 0..<count {
            let entry = 12 + i * 16
            guard entry + 16 <= bytes.count else { break }
            let name = String(decoding: bytes[entry..<entry + 4], as: UTF8.self)
            found[name] = (Self.u32(bytes, entry + 8), Self.u32(bytes, entry + 12))
        }
        for (name, value) in found { tables[name] = (value.0, value.1) }
        guard let head = tables["head"], let maxp = tables["maxp"], let hhea = tables["hhea"],
              tables["glyf"] != nil, tables["loca"] != nil, tables["hmtx"] != nil, tables["cmap"] != nil
        else { return nil }
        unitsPerEm = max(1, Self.u16(bytes, head.offset + 18))
        longLoca = Self.i16(bytes, head.offset + 50) != 0
        numGlyphs = Self.u16(bytes, maxp.offset + 4)
        ascender = Self.i16(bytes, hhea.offset + 4)
        descender = Self.i16(bytes, hhea.offset + 6)
        lineGap = Self.i16(bytes, hhea.offset + 8)
        numHMetrics = max(1, Self.u16(bytes, hhea.offset + 34))

        if let cmap = tables["cmap"] {
            let n = Self.u16(bytes, cmap.offset + 2)
            var candidates: [(rank: Int, format: Int, offset: Int)] = []
            for i in 0..<n {
                let record = cmap.offset + 4 + i * 8
                let platform = Self.u16(bytes, record), encoding = Self.u16(bytes, record + 2)
                let offset = cmap.offset + Self.u32(bytes, record + 4)
                let format = Self.u16(bytes, offset)
                guard format == 4 || format == 12 else { continue }
                // Prefer full-Unicode subtables, then BMP.
                let rank: Int
                switch (platform, encoding, format) {
                case (3, 10, 12), (0, 4, 12): rank = 0
                case (3, 1, 4), (0, 3, 4): rank = 1
                default: rank = 2
                }
                candidates.append((rank, format, offset))
            }
            cmapOffsets = candidates.sorted { $0.rank < $1.rank }.map { ($0.format, $0.offset) }
        }

        if let os2 = tables["OS/2"], Self.u16(bytes, os2.offset) >= 2, os2.length >= 90 {
            capHeight = Self.i16(bytes, os2.offset + 88)
        }
        if capHeight <= 0, let h = glyphIndex(for: "H") {
            capHeight = Int(contours(glyph: h).joined().map(\.y).max() ?? 0)
        }
    }

    // MARK: - Metrics / lookup

    public func glyphIndex(for scalar: Unicode.Scalar) -> Int? {
        let code = Int(scalar.value)
        for sub in cmapOffsets {
            let glyph = sub.format == 4 ? lookup4(sub.offset, code) : lookup12(sub.offset, code)
            if glyph > 0 { return glyph }
        }
        return nil
    }

    /// Horizontal advance in font units.
    public func advance(glyph: Int) -> Int {
        guard let hmtx = tables["hmtx"] else { return 0 }
        let index = min(max(0, glyph), numHMetrics - 1)
        return Self.u16(bytes, hmtx.offset + index * 4)
    }

    private func lookup4(_ base: Int, _ code: Int) -> Int {
        guard code <= 0xFFFF else { return 0 }
        let segCount = Self.u16(bytes, base + 6) / 2
        let endCodes = base + 14
        let startCodes = endCodes + segCount * 2 + 2
        let deltas = startCodes + segCount * 2
        let rangeOffsets = deltas + segCount * 2
        var lo = 0, hi = segCount - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if code > Self.u16(bytes, endCodes + mid * 2) { lo = mid + 1 }
            else if code < Self.u16(bytes, startCodes + mid * 2) { hi = mid - 1 }
            else {
                let start = Self.u16(bytes, startCodes + mid * 2)
                let delta = Self.u16(bytes, deltas + mid * 2)
                let rangeOffset = Self.u16(bytes, rangeOffsets + mid * 2)
                if rangeOffset == 0 { return (code + delta) & 0xFFFF }
                let at = rangeOffsets + mid * 2 + rangeOffset + (code - start) * 2
                let glyph = Self.u16(bytes, at)
                return glyph == 0 ? 0 : (glyph + delta) & 0xFFFF
            }
        }
        return 0
    }

    private func lookup12(_ base: Int, _ code: Int) -> Int {
        let groups = Self.u32(bytes, base + 12)
        var lo = 0, hi = groups - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let g = base + 16 + mid * 12
            let start = Self.u32(bytes, g), end = Self.u32(bytes, g + 4)
            if code > end { lo = mid + 1 } else if code < start { hi = mid - 1 }
            else { return Self.u32(bytes, g + 8) + (code - start) }
        }
        return 0
    }

    // MARK: - Outlines

    /// Contours of `glyph` in font units, y-up, composites resolved.
    public func contours(glyph: Int) -> [[Point]] { contours(glyph: glyph, depth: 0) }

    private func glyphRange(_ glyph: Int) -> Range<Int>? {
        guard glyph >= 0, glyph < numGlyphs, let loca = tables["loca"], let glyf = tables["glyf"] else { return nil }
        let start: Int, end: Int
        if longLoca {
            start = Self.u32(bytes, loca.offset + glyph * 4)
            end = Self.u32(bytes, loca.offset + glyph * 4 + 4)
        } else {
            start = Self.u16(bytes, loca.offset + glyph * 2) * 2
            end = Self.u16(bytes, loca.offset + glyph * 2 + 2) * 2
        }
        guard end > start, glyf.offset + end <= bytes.count else { return nil }   // empty glyph (space)
        return (glyf.offset + start)..<(glyf.offset + end)
    }

    private func contours(glyph: Int, depth: Int) -> [[Point]] {
        guard depth < 8, let range = glyphRange(glyph) else { return [] }
        let base = range.lowerBound
        let numberOfContours = Self.i16(bytes, base)
        return numberOfContours >= 0
            ? simpleContours(base: base, count: numberOfContours, end: range.upperBound)
            : compositeContours(base: base, end: range.upperBound, depth: depth)
    }

    private func simpleContours(base: Int, count: Int, end: Int) -> [[Point]] {
        guard count > 0 else { return [] }
        var cursor = base + 10
        var endPoints: [Int] = []
        for _ in 0..<count { endPoints.append(Self.u16(bytes, cursor)); cursor += 2 }
        let pointCount = (endPoints.last ?? -1) + 1
        guard pointCount > 0, pointCount < 20_000 else { return [] }
        cursor += 2 + Self.u16(bytes, cursor)                       // skip instructions

        var flags: [UInt8] = []
        flags.reserveCapacity(pointCount)
        while flags.count < pointCount, cursor < end {
            let flag = bytes[cursor]; cursor += 1
            flags.append(flag)
            if flag & 8 != 0, cursor < end {
                let repeats = Int(bytes[cursor]); cursor += 1
                for _ in 0..<repeats where flags.count < pointCount { flags.append(flag) }
            }
        }
        guard flags.count == pointCount else { return [] }

        func coordinates(short: UInt8, same: UInt8) -> [Int] {
            var out: [Int] = []; out.reserveCapacity(pointCount)
            var value = 0
            for flag in flags {
                if flag & short != 0 {
                    guard cursor < end else { return out }
                    let delta = Int(bytes[cursor]); cursor += 1
                    value += flag & same != 0 ? delta : -delta
                } else if flag & same == 0 {
                    value += Self.i16(bytes, cursor); cursor += 2
                }
                out.append(value)
            }
            return out
        }
        let xs = coordinates(short: 2, same: 16)
        let ys = coordinates(short: 4, same: 32)
        guard xs.count == pointCount, ys.count == pointCount else { return [] }

        var result: [[Point]] = []
        var start = 0
        for endPoint in endPoints {
            guard endPoint >= start, endPoint < pointCount else { return result }
            result.append((start...endPoint).map {
                Point(x: Float(xs[$0]), y: Float(ys[$0]), onCurve: flags[$0] & 1 != 0)
            })
            start = endPoint + 1
        }
        return result
    }

    private func compositeContours(base: Int, end: Int, depth: Int) -> [[Point]] {
        var cursor = base + 10
        var result: [[Point]] = []
        while cursor + 4 <= end {
            let flags = Self.u16(bytes, cursor)
            let component = Self.u16(bytes, cursor + 2)
            cursor += 4
            var dx: Float = 0, dy: Float = 0
            if flags & 0x0001 != 0 {                                 // ARG_1_AND_2_ARE_WORDS
                if flags & 0x0002 != 0 { dx = Float(Self.i16(bytes, cursor)); dy = Float(Self.i16(bytes, cursor + 2)) }
                cursor += 4
            } else {
                if flags & 0x0002 != 0 { dx = Float(Self.i8(bytes, cursor)); dy = Float(Self.i8(bytes, cursor + 1)) }
                cursor += 2
            }
            var a: Float = 1, b: Float = 0, c: Float = 0, d: Float = 1
            func f2dot14(_ at: Int) -> Float { Float(Self.i16(bytes, at)) / 16384 }
            if flags & 0x0008 != 0 { a = f2dot14(cursor); d = a; cursor += 2 }
            else if flags & 0x0040 != 0 { a = f2dot14(cursor); d = f2dot14(cursor + 2); cursor += 4 }
            else if flags & 0x0080 != 0 {
                a = f2dot14(cursor); b = f2dot14(cursor + 2); c = f2dot14(cursor + 4); d = f2dot14(cursor + 6); cursor += 8
            }
            for contour in contours(glyph: component, depth: depth + 1) {
                result.append(contour.map {
                    Point(x: a * $0.x + c * $0.y + dx, y: b * $0.x + d * $0.y + dy, onCurve: $0.onCurve)
                })
            }
            if flags & 0x0020 == 0 { break }                          // MORE_COMPONENTS
        }
        return result
    }

    // MARK: - Byte access (all bounds-checked; out of range reads 0)

    private static func u8(_ b: [UInt8], _ o: Int) -> Int { o >= 0 && o < b.count ? Int(b[o]) : 0 }
    private static func i8(_ b: [UInt8], _ o: Int) -> Int { Int(Int8(truncatingIfNeeded: u8(b, o))) }
    private static func u16(_ b: [UInt8], _ o: Int) -> Int { u8(b, o) << 8 | u8(b, o + 1) }
    private static func i16(_ b: [UInt8], _ o: Int) -> Int { Int(Int16(truncatingIfNeeded: u16(b, o))) }
    private static func u32(_ b: [UInt8], _ o: Int) -> Int { u16(b, o) << 16 | u16(b, o + 2) }
}
