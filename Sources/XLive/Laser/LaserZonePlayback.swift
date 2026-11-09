import Foundation

/// A zone while it plays: the stream of scanner samples that feeds it, the one ring
/// those samples are written to, and the producer that writes them. This is the run-time
/// handle `LaserOutputStreams` keeps for a `LaserZone`, not the zone itself (the zone is
/// an `XLive` value that holds the settings and the mastering).
///
/// Everything that makes the samples is common to the outputs of the zone, and each output
/// only reads the ring on its own clock; its own rate conversion and masks are added by
/// `LaserOutputStreams`. One output belongs to one zone. What fills it is a
/// `Laser2DStream` (see `LaserScannerChain`, which starts with mastering) or any sequence
/// of sample chunks.
///
/// The producer writes at its own pace and waits when the ring is full for the output
/// furthest ahead, so a slow producer cannot stall a pump and a slow output cannot
/// stall another (see `LaserSampleRing`).
final class LaserZonePlayback: @unchecked Sendable {
    let id: UUID
    /// Points per second of the samples in the ring.
    let rate: UInt32
    let ring: LaserSampleRing
    private let lock = NSLock()
    private var producer: Task<Void, Never>?
    private var failed: String?

    init(id: UUID, rate: UInt32, bufferSamples: Int) {
        self.id = id; self.rate = rate
        ring = LaserSampleRing(capacity: max(1, bufferSamples))
    }

    /// What ended the producer, if it ended on an error.
    var failure: String? { lock.withLock { failed } }

    /// Starts filling the ring from `source`.
    func start<Source: AsyncSequence & Sendable>(_ source: Source) where Source.Element == [LaserPoint] {
        let task = Task { [ring, weak self] in
            do {
                for try await chunk in source { try await ring.push(chunk) }
            } catch is CancellationError {
            } catch {
                self?.fail(error.localizedDescription)
            }
        }
        lock.withLock { producer = task }
    }

    /// Stops the producer and drops what was buffered.
    func stop() {
        let task = lock.withLock { () -> Task<Void, Never>? in defer { producer = nil }; return producer }
        task?.cancel()
        ring.clear()
    }

    private func fail(_ message: String) { lock.withLock { failed = message } }
}
