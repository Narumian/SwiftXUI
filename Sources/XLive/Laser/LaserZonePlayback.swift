import Foundation

final class LaserZonePlayback: @unchecked Sendable {
    private struct SourceMetrics {
        var pulls = 0
        var chunks = 0
        var samples = 0
        var blanked = 0
        var emptyChunks = 0
        var latePulls = 0
        var totalPullNanoseconds: UInt64 = 0
        var maxPullNanoseconds: UInt64 = 0
        var maxPushNanoseconds: UInt64 = 0
        var maxFill = 0
        var recent: [String] = []

        mutating func recordPull(_ chunk: [LaserPoint]?, elapsed: UInt64, fill: Int, rate: UInt32) {
            pulls += 1
            totalPullNanoseconds &+= elapsed
            maxPullNanoseconds = max(maxPullNanoseconds, elapsed)
            let budget = UInt64(Double(fill) / Double(max(1, rate)) * 1_000_000_000)
            if elapsed > budget { latePulls += 1 }
            if let chunk {
                chunks += 1
                samples += chunk.count
                blanked += chunk.reduce(into: 0) { if $1.isBlanked { $0 += 1 } }
                if chunk.isEmpty { emptyChunks += 1 }
                let ms = Double(elapsed) / 1_000_000
                recent.append(String(format: "%.1fms/f%d/n%d/b%d", ms, fill, chunk.count, chunk.reduce(into: 0) { if $1.isBlanked { $0 += 1 } }))
                if recent.count > 16 { recent.removeFirst() }
            }
        }

        mutating func recordPush(elapsed: UInt64, fill: Int) {
            maxPushNanoseconds = max(maxPushNanoseconds, elapsed)
            maxFill = max(maxFill, fill)
        }

        var description: String {
            let average = pulls > 0 ? Double(totalPullNanoseconds) / Double(pulls) / 1_000_000 : 0
            return String(format: "sourcePulls=%d chunks=%d samples=%d blank=%d empty=%d late=%d avgNext=%.2fms maxNext=%.2fms maxPush=%.2fms maxFill=%d recent=[%@]",
                          pulls, chunks, samples, blanked, emptyChunks, latePulls, average,
                          Double(maxPullNanoseconds) / 1_000_000, Double(maxPushNanoseconds) / 1_000_000,
                          maxFill, recent.joined(separator: " "))
        }
    }

    let id: UUID
    let rate: UInt32
    let ring: LaserSampleRing
    private let lock = NSLock()
    private var producer: Task<Void, Never>?
    private var failed: String?
    private var sourceMetrics = SourceMetrics()

    init(id: UUID, rate: UInt32, bufferSamples: Int) {
        self.id = id; self.rate = rate
        ring = LaserSampleRing(capacity: max(1, bufferSamples), maximumReaderLagSamples: max(1, Int(rate) / 200))
    }

    var failure: String? { lock.withLock { failed } }
    var sourceDiagnostics: String { lock.withLock { sourceMetrics.description } }

    func start<Source: AsyncSequence & Sendable>(_ source: Source) where Source.Element == [LaserPoint] {
        let task = Task { [ring, weak self] in
            do {
                var iterator = source.makeAsyncIterator()
                while !Task.isCancelled {
                    try await ring.waitForAvailableLength(atMost: 512)
                    let fill = ring.availableLength
                    let started = DispatchTime.now().uptimeNanoseconds
                    guard let chunk = try await iterator.next() else { break }
                    let generated = DispatchTime.now().uptimeNanoseconds &- started
                    self?.recordPull(chunk, elapsed: generated, fill: fill)
                    let pushStarted = DispatchTime.now().uptimeNanoseconds
                    try await ring.push(chunk)
                    self?.recordPush(elapsed: DispatchTime.now().uptimeNanoseconds &- pushStarted)
                }
            } catch is CancellationError {
            } catch {
                self?.fail(error.localizedDescription)
            }
        }
        lock.withLock { producer = task }
    }

    func stop() {
        let task = lock.withLock { () -> Task<Void, Never>? in defer { producer = nil }; return producer }
        task?.cancel()
        ring.clear()
    }

    private func fail(_ message: String) { lock.withLock { failed = message } }

    private func recordPull(_ chunk: [LaserPoint], elapsed: UInt64, fill: Int) {
        lock.withLock { sourceMetrics.recordPull(chunk, elapsed: elapsed, fill: fill, rate: rate) }
    }

    private func recordPush(elapsed: UInt64) {
        lock.withLock { sourceMetrics.recordPush(elapsed: elapsed, fill: ring.availableLength) }
    }
}
