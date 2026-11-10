import Foundation

/// One whole shape in the back half of the pipeline (2D, after projection): the samples
/// the beam plays for it, in scanner space, with the identity its producer gave it.
/// Padding, spacing and everything else the back half does keeps the shape apart, so a
/// stage can tell where one shape ends and the next begins.
public struct Laser2DShape: Equatable, Sendable {
    public var id: LaserShapeID
    public var points: [LaserPoint]

    public init(id: LaserShapeID, points: [LaserPoint]) { self.id = id; self.points = points }
    public var isEmpty: Bool { points.isEmpty }
}

/// A source of scanner samples in the back half of the pipeline (2D, `LaserPoint`),
/// what an output plays. Each `read` answers
/// with the shapes of one frame, every one of them whole, and an empty array means
/// there is nothing to play now. `read` never waits.
public protocol Laser2DStream: Sendable {
    /// Points per second the samples are meant to play at; nil where time is not yet fixed.
    var rate: UInt32? { get }
    mutating func read() -> [Laser2DShape]
}

/// Sits on the consuming side of a stream and turns "give me what you have" into
/// exactly the number of samples a consumer needs, keeping any surplus for next time.
/// It does not wait and does not invent data: a short result means the stream had
/// nothing more this round.
public struct LaserReader<Stream: Laser2DStream>: Sendable {
    public private(set) var stream: Stream
    private var pending: [LaserPoint] = []
    private var pendingStart = 0
    /// The last sample handed out, kept so a starved output can go dark where it stopped.
    public private(set) var lastPoint: LaserPoint?
    /// Stops a stream that returns very little at a time from being asked forever.
    public var maximumReadsPerTake = 8

    public init(_ stream: Stream) { self.stream = stream }

    public var rate: UInt32? { stream.rate }
    /// Samples read from the stream but not yet handed out.
    public var surplus: Int { pending.count - pendingStart }

    /// Up to `count` samples: fewer only if the stream ran dry.
    public mutating func take(_ count: Int) -> [LaserPoint] {
        var out: [LaserPoint] = []
        guard count > 0 else { return out }
        out.reserveCapacity(count)
        var reads = 0
        while out.count < count {
            if pendingStart == pending.count {
                guard reads < maximumReadsPerTake else { break }
                reads += 1
                let next = stream.read().flatMap(\.points)
                if next.isEmpty { break }
                pending = next; pendingStart = 0
            }
            let used = min(pending.count - pendingStart, count - out.count)
            out.append(contentsOf: pending[pendingStart..<(pendingStart + used)])
            pendingStart += used
        }
        if let last = out.last { lastPoint = last }
        return out
    }

    /// Exactly `count` samples for a pump. If the stream ran dry the rest is
    /// blanked and parked where the last sample was (or at the centre before any),
    /// so a late source darkens the output instead of holding a lit point.
    public mutating func takeFilled(_ count: Int) -> [LaserPoint] {
        var points = take(count)
        if points.count < count {
            let at = lastPoint?.xy ?? .zero
            let dark = try! LaserPoint(xy: at, rgb: .zero, isBlanked: true)
            points.append(contentsOf: Array(repeating: dark, count: count - points.count))
        }
        return points
    }
}
