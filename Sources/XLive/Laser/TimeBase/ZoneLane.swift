import Foundation

/// How an output follows the zone.
public struct ZoneLaneSettings: Sendable, Equatable {
    /// The most the conversion step may differ from the ratio of the rates (0.03 is three percent). A device's own
    /// clock can differ from its nominal rate by a percent, and the trim is what absorbs that.
    public var trimLimit = 0.03
    /// The time in which a position error is brought back to zero, in seconds: the proportional part of the trim is
    /// `error / trimTime`.
    public var trimTime = 2.0
    /// The integral part learns the device's clock error: it adds `error / integralTime` to the trim every second, so
    /// a steady error (a clock that is off by a constant factor) goes to zero instead of staying at `skew * trimTime`.
    public var integralTime = 12.0
    /// The integral part is kept within this (0.015 is one and a half percent), and only grows while the error is within
    /// `integralWindow` seconds: a stall or a jump must not wind it up.
    public var integralLimit = 0.015
    public var integralWindow = 0.02
    /// An error beyond this many seconds is not trimmed but jumped over (to a frame start where there is one close).
    public var jumpThreshold = 0.06
    public init() {}
}

/// One output's way of reading the zone's ring: it turns the zone's points into the points its device plays, and keeps
/// them in step with the clock.
///
/// The step through the zone is the ratio of the rates (zone rate over output rate), trimmed a little by how far the
/// device's playing position is from where the clock says the zone is. The ratio takes care of the rates (30k and 20k
/// devices of one 50k zone) and the trim of the clocks of the devices (parts per million). An error too big to trim
/// away is jumped over and counted. If the zone has nothing yet, the lane plays dark and counts it; it never stops.
public final class ZoneLane: @unchecked Sendable {
    public let zoneRate: Double
    public let outputRate: Double
    public let epoch: Double
    public let settings: ZoneLaneSettings
    private let reader: ZoneRing.Reader
    private let ring: ZoneRing

    private var buffer: [LaserPoint] = []
    private var bufferIndex = 0
    private var current: LaserPoint?
    private var following: LaserPoint?
    private var phase = 0.0
    private var lastLost = 0
    private var started = false
    private var integral = 0.0
    private var lastTime: Double?
    private var lastPoint: LaserPoint = LaserPoint.blackCenter(count: 1)[0]

    public private(set) var jumps = 0
    public private(set) var jumpedSamples = 0
    public private(set) var underrunSamples = 0
    public private(set) var errorSeconds = 0.0
    public private(set) var trim = 0.0
    public private(set) var emittedSamples = 0

    /// - Parameters:
    ///   - epoch: the clock time of point 0 of the ring (`ZoneProducer.epoch`).
    ///   - now: when the lane was made. The lane starts reading at its first block, since where it starts depends on
    ///     what the device holds by then.
    public init(ring: ZoneRing, zoneRate: UInt32, outputRate: UInt32, epoch: Double, now: Double,
                settings: ZoneLaneSettings = ZoneLaneSettings()) {
        self.ring = ring
        self.zoneRate = Double(max(1, zoneRate)); self.outputRate = Double(max(1, outputRate))
        self.epoch = epoch; self.settings = settings
        reader = ring.makeReader()
        lastLost = reader.lostSamples
    }

    public var skippedSamples: Int { reader.skippedSamples }
    public var lostSamples: Int { reader.lostSamples }
    /// The ratio of the rates: how many zone points one output point steps over.
    public var nominalStep: Double { zoneRate / outputRate }

    /// The next `count` points for the device, made at time `now`. `queued` is how many output points the device
    /// already holds and has not played, so the position it is playing is that much behind the position this lane read to.
    public func makeBlock(count: Int, now: Double, queued: Int = 0) -> [LaserPoint] {
        guard count > 0 else { return [] }
        let desired = (now - epoch) * zoneRate
        let queuedZone = Double(max(0, queued)) * nominalStep
        if !started {
            // What the device already holds is not ours and plays first, so our first point is wanted that much later.
            started = true
            reader.seek(to: Int((desired + queuedZone).rounded()))
            lastLost = reader.lostSamples
        }
        if reader.lostSamples != lastLost { lastLost = reader.lostSamples; reset() }
        var error = (readPosition - queuedZone - desired) / zoneRate
        if abs(error) > settings.jumpThreshold {
            jump(to: desired + queuedZone)
            error = (readPosition - queuedZone - desired) / zoneRate
        }
        errorSeconds = error
        if let last = lastTime {
            let dt = min(0.2, max(0, now - last))
            if abs(error) <= settings.integralWindow {
                integral = min(settings.integralLimit, max(-settings.integralLimit, integral + error * dt / settings.integralTime))
            }
        }
        lastTime = now
        let factor = min(1 + settings.trimLimit, max(1 - settings.trimLimit, 1 - error / settings.trimTime - integral))
        trim = factor - 1
        let step = nominalStep * factor

        var out: [LaserPoint] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            if current == nil { current = fetch() }
            if following == nil { following = fetch() }
            while phase >= 1, let next = following {
                current = next
                following = fetch()
                phase -= 1
            }
            guard let a = current, let b = following, phase < 1 else {
                // Nothing to play yet: hold the last position, dark.
                lastPoint = lastPoint.blanked()
                out.append(lastPoint)
                underrunSamples += 1
                continue
            }
            let point = Self.lerp(a, b, Float(phase))
            out.append(point)
            lastPoint = point
            phase += step
        }
        emittedSamples += count
        return out
    }

    /// The position in the ring, in zone points, that the next output point will come from.
    private var readPosition: Double {
        let loaded = (current == nil ? 0 : 1) + (following == nil ? 0 : 1)
        let nextToLoad = reader.position - (buffer.count - bufferIndex)
        return Double(nextToLoad - loaded) + phase
    }

    private func fetch() -> LaserPoint? {
        if bufferIndex == buffer.count {
            buffer = reader.read(64)
            bufferIndex = 0
            if buffer.isEmpty { return nil }
        }
        defer { bufferIndex += 1 }
        return buffer[bufferIndex]
    }

    private func reset() {
        buffer = []; bufferIndex = 0
        current = nil; following = nil; phase = 0
    }

    private func jump(to position: Double) {
        let before = readPosition
        var target = Int(position.rounded())
        // Land on the start of a frame if one is close ahead, so a frame is not cut in two.
        if let start = reader.frameStart(atOrAfter: target), Double(start - target) <= settings.jumpThreshold * zoneRate / 2 {
            target = start
        }
        reset()
        let reached = reader.seek(to: target)
        jumps += 1
        jumpedSamples += Int(abs(Double(reached) - before))
    }

    private static func lerp(_ a: LaserPoint, _ b: LaserPoint, _ t: Float) -> LaserPoint {
        if t == 0 { return a }
        func mix(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        let xy = SIMD2<Float>(min(1, max(-1, mix(a.xy.x, b.xy.x))), min(1, max(-1, mix(a.xy.y, b.xy.y))))
        let rgb = SIMD3<Float>(min(1, max(0, mix(a.rgb.x, b.rgb.x))), min(1, max(0, mix(a.rgb.y, b.rgb.y))), min(1, max(0, mix(a.rgb.z, b.rgb.z))))
        return try! LaserPoint(xy: xy, rgb: rgb, mode: a.isBlanked || b.isBlanked ? .blank : .normal)
    }
}
