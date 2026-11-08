import Foundation
import simd

/// A shape's identity: a stable integer chosen by whoever produces the shape.
/// It is not the shape's index. An index is a position in one frame and changes
/// when shapes are added or reordered; an identity names the same shape across
/// frames, so effects, materials, morphs and routing can address it.
public struct LaserShapeID: Hashable, Sendable, ExpressibleByIntegerLiteral {
    public var rawValue: UInt32
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
    public init(integerLiteral value: UInt32) { rawValue = value }
}

/// A range of one chunk's elements that belong to a single shape.
public struct LaserRun: Equatable, Sendable {
    public var id: LaserShapeID
    public var range: Range<Int>
    public init(id: LaserShapeID, range: Range<Int>) { self.id = id; self.range = range }
}

/// A vertex before projection onto the scanner. The position is homogeneous
/// (x, y, z, w) so 2D and 3D shapes share one type: a 2D shape uses z = 0 and
/// w = 1, and the projection stage divides by w. Geometry is `Double` because
/// transforms are stacked as matrices; the projection stage narrows to the
/// `Float` of `LaserPoint`. Nothing here is limited to the scanner's -1...1
/// range; clipping happens at projection.
public struct LaserVertex: Equatable, Sendable {
    /// The scanner's treatment of this vertex; the same type a `LaserPoint` carries.
    public typealias Mode = LaserPointMode

    public var position: SIMD4<Double>
    /// Colour with alpha. Alpha is multiplied into the colour at projection.
    public var rgba: SIMD4<Double>
    public var mode: Mode

    public init(position: SIMD4<Double>, rgba: SIMD4<Double>, mode: Mode = .normal) {
        self.position = position; self.rgba = rgba; self.mode = mode
    }
    public init(x: Double, y: Double, z: Double = 0, w: Double = 1, rgba: SIMD4<Double> = .one, mode: Mode = .normal) {
        self.init(position: SIMD4<Double>(x, y, z, w), rgba: rgba, mode: mode)
    }

    public var xy: SIMD2<Double> { SIMD2<Double>(position.x, position.y) }
    public var isBlanked: Bool { mode == .blank }

    /// The same place, dark.
    public func blanked() -> LaserVertex { var v = self; v.rgba = .zero; v.mode = .blank; return v }
    /// The same place and colour, held still.
    public func dwelling() -> LaserVertex { var v = self; v.mode = .dwell; return v }
    public func transformed(by matrix: simd_double4x4) -> LaserVertex { var v = self; v.position = matrix * position; return v }
    public func scaledAlpha(_ alpha: Double) -> LaserVertex { var v = self; v.rgba.w *= alpha; return v }
}

/// What a stream carries and, for scanner samples, how fast it is meant to play.
public struct LaserStreamFormat: Equatable, Sendable {
    public enum Domain: Equatable, Sendable {
        /// `LaserVertex` shapes in their own space, before projection.
        case shapes
        /// `LaserPoint` samples in scanner space, ready for an output.
        case scanner
    }
    public var domain: Domain
    /// Points per second of a scanner stream; nil where time is not yet fixed.
    public var rate: UInt32?
    public init(domain: Domain, rate: UInt32? = nil) { self.domain = domain; self.rate = rate }
}

/// A piece of a stream. Besides the elements it says which stretches belong to
/// which shape and where frames end, so a consumer never has to guess either from
/// the data. `runs` are ordered and do not overlap; `frameEnds` are exclusive end
/// offsets within this chunk, ascending, each in 1...count.
public struct LaserChunk<Element: Sendable>: Sendable {
    public var elements: [Element]
    public var runs: [LaserRun]
    public var frameEnds: [Int]
    public init(elements: [Element] = [], runs: [LaserRun] = [], frameEnds: [Int] = []) {
        self.elements = elements; self.runs = runs; self.frameEnds = frameEnds
    }
    /// A chunk that belongs entirely to one shape.
    public init(elements: [Element], shape: LaserShapeID) {
        self.init(elements: elements, runs: elements.isEmpty ? [] : [LaserRun(id: shape, range: 0..<elements.count)])
    }
    public var count: Int { elements.count }
    public var isEmpty: Bool { elements.isEmpty }

    /// The elements in `range`, with runs and frame ends re-based to its start.
    public func slice(_ range: Range<Int>) -> LaserChunk {
        let bounds = range.clamped(to: 0..<count)
        var sliced = LaserChunk(elements: Array(elements[bounds]))
        for run in runs {
            let lower = max(run.range.lowerBound, bounds.lowerBound), upper = min(run.range.upperBound, bounds.upperBound)
            if lower < upper { sliced.runs.append(LaserRun(id: run.id, range: (lower - bounds.lowerBound)..<(upper - bounds.lowerBound))) }
        }
        sliced.frameEnds = frameEnds.filter { $0 > bounds.lowerBound && $0 <= bounds.upperBound }.map { $0 - bounds.lowerBound }
        return sliced
    }

    /// Appends `other` after this chunk, joining a run that continues across the seam.
    public mutating func append(_ other: LaserChunk) {
        let base = count
        elements.append(contentsOf: other.elements)
        for run in other.runs {
            let shifted = (run.range.lowerBound + base)..<(run.range.upperBound + base)
            if let last = runs.last, last.id == run.id, last.range.upperBound == shifted.lowerBound {
                runs[runs.count - 1].range = last.range.lowerBound..<shifted.upperBound
            } else {
                runs.append(LaserRun(id: run.id, range: shifted))
            }
        }
        frameEnds.append(contentsOf: other.frameEnds.map { $0 + base })
    }
}

/// A source of elements that can be asked for a number of them but need not
/// deliver that number. Callers say how many they would like; a stream may return
/// fewer (it has no more right now), or more (a whole frame at once), and a caller
/// that is still short asks again.
///
/// An empty chunk means nothing is available now, not that the stream has ended;
/// callers stop asking for that round. `read` never waits, so a real-time pump can
/// call it. Sources that need to wait feed a buffer (see `LaserSampleRing`) that
/// the pump reads without waiting.
public protocol LaserStream: Sendable {
    associatedtype Element: Sendable
    var format: LaserStreamFormat { get }
    mutating func read(wanting count: Int) -> LaserChunk<Element>
}

/// A stream of scanner-space samples: the 2D end of the pipeline, what an output
/// plays. Everything before the projection stage is a `LaserStream` of vertices.
public protocol LaserOutputStream: LaserStream where Element == LaserPoint {}

/// Sits on the consuming side of a stream and turns "I would like n, give what you
/// have" into exactly the amount a consumer needs, keeping any surplus for next
/// time. It does not wait and does not invent data: a short result means the
/// stream had nothing more this round.
public struct LaserReader<Stream: LaserStream>: Sendable {
    public private(set) var stream: Stream
    private var pending = LaserChunk<Stream.Element>()
    private var pendingStart = 0
    /// The last element handed out, kept so a starved output can go dark where it stopped.
    public private(set) var lastElement: Stream.Element?
    /// Stops a stream that returns one element at a time from being asked forever.
    public var maximumReadsPerTake = 8

    public init(_ stream: Stream) { self.stream = stream }

    public var format: LaserStreamFormat { stream.format }
    /// Elements read from the stream but not yet handed out.
    public var surplus: Int { pending.count - pendingStart }

    /// Up to `count` elements: fewer only if the stream ran dry.
    public mutating func take(_ count: Int) -> LaserChunk<Stream.Element> {
        var out = LaserChunk<Stream.Element>()
        guard count > 0 else { return out }
        var reads = 0
        while out.count < count {
            if pendingStart == pending.count {
                guard reads < maximumReadsPerTake else { break }
                reads += 1
                let next = stream.read(wanting: count - out.count)
                if next.isEmpty { break }
                pending = next; pendingStart = 0
            }
            let available = pending.count - pendingStart
            let used = min(available, count - out.count)
            out.append(pending.slice(pendingStart..<(pendingStart + used)))
            pendingStart += used
        }
        if let last = out.elements.last { lastElement = last }
        return out
    }
}

extension LaserReader where Stream: LaserOutputStream {
    /// Exactly `count` samples for a pump. If the stream ran dry the rest is
    /// blanked and parked where the last sample was (or at the centre before any),
    /// so a late source darkens the output instead of holding a lit point.
    public mutating func takeFilled(_ count: Int) -> [LaserPoint] {
        var points = take(count).elements
        if points.count < count {
            let at = lastElement?.xy ?? .zero
            let dark = try! LaserPoint(xy: at, rgb: .zero, isBlanked: true)
            points.append(contentsOf: Array(repeating: dark, count: count - points.count))
        }
        return points
    }
}

/// Plays one frame over and over and swaps in a newer one at the frame boundary,
/// like a projector redrawing the latest picture. Producers call `submit` from any
/// thread; the reader gets the rest of the current frame on each `read` whatever
/// number it asked for, with the frame end marked.
public final class LaserFrameLooper<Element: Sendable>: LaserStream, @unchecked Sendable {
    public let format: LaserStreamFormat
    private let lock = NSLock()
    private var current = LaserChunk<Element>()
    private var offset = 0
    private var next: LaserChunk<Element>?

    public init(format: LaserStreamFormat) { self.format = format }

    /// Replaces the frame at its next boundary. A newer submission before then wins.
    public func submit(_ frame: LaserChunk<Element>) {
        var frame = frame
        frame.frameEnds = frame.isEmpty ? [] : [frame.count]
        lock.withLock { if current.isEmpty { current = frame; offset = 0 } else { next = frame } }
    }

    /// Stops drawing anything until the next `submit`.
    public func clear() { lock.withLock { current = .init(); next = nil; offset = 0 } }

    public func read(wanting count: Int) -> LaserChunk<Element> {
        lock.withLock {
            if offset >= current.count {
                if let waiting = next { current = waiting; next = nil }
                offset = 0
            }
            guard !current.isEmpty else { return LaserChunk() }
            let piece = current.slice(offset..<current.count)
            offset = current.count
            return piece
        }
    }
}
