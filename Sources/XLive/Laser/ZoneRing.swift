import Foundation

/// The zone's samples, one writer and any number of readers. Points are numbered from the first one written, and
/// every position (`writtenCount`, a reader's `position`) is such a number, so a reader keeps its place however far
/// the ring has turned.
///
/// The writer never waits for a reader and a reader never waits for the writer: the ring overwrites its oldest
/// points, and a reader that fell more than `capacity` behind is moved to the oldest point and told how many it
/// lost. One slow or stopped output therefore cannot hold back the zone or another output.
public final class ZoneRing: @unchecked Sendable {
    public let capacity: Int
    private let lock = NSLock()
    private var storage: [LaserPoint]
    private var written = 0
    /// Where frames begin, in increasing order; only the ones still inside the ring are kept.
    private var frameStarts: [Int] = []

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = Array(repeating: LaserPoint.blackCenter(count: 1)[0], count: capacity)
    }

    /// The number of points written so far, which is also where the next one goes.
    public var writtenCount: Int { lock.withLock { written } }

    /// The number of the oldest point still in the ring.
    public var oldestIndex: Int { lock.withLock { max(0, written - capacity) } }

    /// Appends points; `startsFrame` marks the first of them as the start of a frame, a place a reader may jump to
    /// without cutting a frame in two. Never waits. A write larger than the ring keeps its last `capacity` points.
    public func write(_ points: [LaserPoint], startsFrame: Bool = false) {
        guard !points.isEmpty else { return }
        lock.withLock {
            if startsFrame { frameStarts.append(written) }
            let skipped = max(0, points.count - capacity)
            for index in skipped..<points.count { storage[(written + index) % capacity] = points[index] }
            written += points.count
            let oldest = max(0, written - capacity)
            if let first = frameStarts.firstIndex(where: { $0 >= oldest }) { frameStarts.removeFirst(first) }
            else { frameStarts.removeAll() }
        }
    }

    /// A reader that begins `lag` points behind the writer (or at the oldest point, if fewer are held).
    public func makeReader(lag: Int = 0) -> Reader {
        lock.withLock {
            let start = max(max(0, written - capacity), written - max(0, lag))
            return Reader(ring: self, position: start)
        }
    }

    public final class Reader: @unchecked Sendable {
        private let ring: ZoneRing
        private var next: Int
        private var lost = 0, starved = 0, skipped = 0

        fileprivate init(ring: ZoneRing, position: Int) { self.ring = ring; next = position }

        /// The number of the next point this reader will read.
        public var position: Int { ring.lock.withLock { next } }

        /// How many points are written and not yet read, at most `capacity`.
        public var lag: Int { ring.lock.withLock { min(ring.capacity, ring.written - next) } }

        /// Points overwritten before this reader got to them.
        public var lostSamples: Int { ring.lock.withLock { lost } }

        /// Points asked for beyond what was written: the reader got fewer than it asked.
        public var starvedSamples: Int { ring.lock.withLock { starved } }

        /// Points passed over by `seek`, a choice of the reader's.
        public var skippedSamples: Int { ring.lock.withLock { skipped } }

        /// Reads up to `count` points from the reader's position and moves on; never waits. Fewer come back when the
        /// writer has not written that many, and that is counted as starved. A reader the ring has turned past is
        /// first moved to the oldest point, and the points it missed are counted as lost.
        public func read(_ count: Int) -> [LaserPoint] {
            guard count > 0 else { return [] }
            return ring.lock.withLock {
                let oldest = max(0, ring.written - ring.capacity)
                if next < oldest { lost += oldest - next; next = oldest }
                let taken = min(count, ring.written - next)
                var out: [LaserPoint] = []
                out.reserveCapacity(taken)
                for index in next..<(next + taken) { out.append(ring.storage[index % ring.capacity]) }
                next += taken
                if taken < count { starved += count - taken }
                return out
            }
        }

        /// Moves to point `index`, kept within the ring: no earlier than the oldest point and no later than the
        /// writer. Points passed over are counted as skipped. Returns the position it reached.
        @discardableResult
        public func seek(to index: Int) -> Int {
            ring.lock.withLock {
                let oldest = max(0, ring.written - ring.capacity)
                let target = min(ring.written, max(oldest, index))
                if next < oldest { lost += oldest - next; next = oldest }
                if target > next { skipped += target - next }
                next = target
                return next
            }
        }

        /// The start of the first frame at or after `index`, if the writer has marked one that is still held.
        public func frameStart(atOrAfter index: Int) -> Int? {
            ring.lock.withLock {
                var low = 0, high = ring.frameStarts.count
                while low < high {
                    let middle = (low + high) / 2
                    if ring.frameStarts[middle] < index { low = middle + 1 } else { high = middle }
                }
                return low < ring.frameStarts.count ? ring.frameStarts[low] : nil
            }
        }
    }
}
