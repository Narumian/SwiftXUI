import Foundation

/// A deterministic calibration pattern in normalized scanner space: a grid plus
/// the outline of every enabled mask. Mask attenuation is applied to every grid
/// sample, so the grid shows the actual dimming. Outlines are drawn at full
/// preview power regardless of masks so a blackout mask stays visible.
enum LaserPreviewPattern {
    static let intensity: Float = 0.1
    static let packetLength = 140

    /// The closed outline of an enabled, well-formed mask in scanner space (the
    /// first vertex is repeated at the end), or nil when there is nothing to draw.
    static func outline(of mask: LaserMask) -> (path: [SIMD2<Float>], cornerDwell: Int, settle: Int)? {
        guard mask.enabled else { return nil }
        func scanner(_ x: Double, _ y: Double) -> SIMD2<Float>? {
            guard x.isFinite, y.isFinite else { return nil }
            return SIMD2<Float>(Float(min(1, max(-1, 2 * x - 1))), Float(min(1, max(-1, 1 - 2 * y))))
        }
        switch mask.shape {
        case .polygon:
            guard mask.points.count >= 3 else { return nil }
            let path = mask.points.compactMap { scanner($0.x, $0.y) }
            guard path.count == mask.points.count else { return nil }
            return (path + [path[0]], 4, 3)
        case .ellipse:
            guard mask.points.count == 2 else { return nil }
            let a = mask.points[0], b = mask.points[1]
            let cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2
            let rx = abs(b.x - a.x) / 2, ry = abs(b.y - a.y) / 2
            guard rx > 0, ry > 0 else { return nil }
            let segments = 96
            let path = (0...segments).compactMap { i -> SIMD2<Float>? in
                let angle = 2 * Double.pi * Double(i % segments) / Double(segments)
                return scanner(cx + rx * cos(angle), cy + ry * sin(angle))
            }
            guard path.count == segments + 1 else { return nil }
            return (path, 0, 3)
        }
    }

    static func grid(masks: LaserMaskSettings) throws -> [LaserPoint] {
        var points: [LaserPoint] = []
        var position = SIMD2<Float>.zero
        let lines: Float = 6
        let steps = 240
        func append(_ xy: SIMD2<Float>, lit: Bool, masked: Bool = true) throws {
            let maskPoint = MaskPoint(Double((xy.x + 1) / 2), Double((1 - xy.y) / 2))
            let attenuation = lit ? (masked ? masks.multiplier(at: maskPoint) : 1) : 0
            guard attenuation.isFinite else { throw LaserOutputError.invalidPoint }
            let power = intensity * Float(min(1, max(0, attenuation)))
            points.append(try LaserPoint(xy: xy, rgb: SIMD3<Float>(repeating: power), isBlanked: !lit || power == 0))
        }
        func travel(to target: SIMD2<Float>, lit: Bool, masked: Bool = true) throws {
            let from = position
            let distance = max(abs(target.x - from.x), abs(target.y - from.y))
            let count = max(1, Int(ceil(Double(distance) * Double(steps) / 1.6)))
            for i in 1...count {
                let t = Float(i) / Float(count)
                try append(from + (target - from) * t, lit: lit, masked: masked)
            }
            position = target
        }
        for axis in 0..<2 {
            for index in 0..<Int(lines) {
                let coordinate = -0.8 + 1.6 * Float(index) / (lines - 1)
                let reverse = index.isMultiple(of: 2) == false
                let start = axis == 0 ? SIMD2<Float>(reverse ? 0.8 : -0.8, coordinate) : SIMD2<Float>(coordinate, reverse ? 0.8 : -0.8)
                let end = axis == 0 ? SIMD2<Float>(reverse ? -0.8 : 0.8, coordinate) : SIMD2<Float>(coordinate, reverse ? -0.8 : 0.8)
                try travel(to: start, lit: false)
                try travel(to: end, lit: true)
            }
        }
        for mask in masks.masks {
            guard let contour = outline(of: mask) else { continue }
            // Settle blanked on the start point, then light the whole loop. A
            // polygon dwells on each corner so the scanner does not round it off.
            try travel(to: contour.path[0], lit: false)
            for _ in 0..<contour.settle { try append(position, lit: false) }
            for target in contour.path.dropFirst() {
                try travel(to: target, lit: true, masked: false)
                for _ in 0..<contour.cornerDwell { try append(position, lit: true, masked: false) }
            }
        }
        try travel(to: .zero, lit: false)
        // Each transport packet ends black at its current position. If sending
        // stops at a packet boundary, the last sample cannot be a lit point.
        var packetized: [LaserPoint] = []
        packetized.reserveCapacity(points.count + points.count / (packetLength - 1) + 1)
        for point in points {
            packetized.append(point)
            if packetized.count % packetLength == packetLength - 1 {
                packetized.append(try LaserPoint(xy: point.xy, rgb: .zero, isBlanked: true))
            }
        }
        if let last = packetized.last {
            while packetized.count % packetLength != 0 {
                packetized.append(try LaserPoint(xy: last.xy, rgb: .zero, isBlanked: true))
            }
        }
        return packetized
    }
}
