import Foundation

public enum LaserStreamError: Error, LocalizedError, Sendable {
    case notConnected
    case busy
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .notConnected: "No connected output session"
        case .busy: "Output is changing state"
        case .failed(let message): message
        }
    }
}

/// Timing probe for one output's sample pump. A device underruns when the
/// producer's effective rate stays below the point rate, so the numbers that
/// matter are how long each write blocks, the gap between writes, and the
/// resulting samples-per-second since the first write.
public struct LaserStreamStats: Sendable, CustomStringConvertible {
    public var writes = 0
    public var samples = 0
    public var maxWriteMs = 0.0
    public var maxGapMs = 0.0
    public var totalWriteMs = 0.0
    public var elapsedMs = 0.0
    public var recent: [(write: Double, gap: Double)] = []
    var first: UInt64?
    var lastEnd: UInt64?
    public var effectiveRate: Double { elapsedMs > 0 ? Double(samples) / (elapsedMs / 1000) : 0 }
    static func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(to &- from) / 1e6 }
    mutating func record(start: UInt64, end: UInt64, count: Int) {
        if first == nil { first = start }
        let write = Self.ms(start, end)
        let gap = lastEnd.map { Self.ms($0, start) } ?? 0
        writes += 1; samples += count; totalWriteMs += write
        maxWriteMs = max(maxWriteMs, write); maxGapMs = max(maxGapMs, gap)
        elapsedMs = Self.ms(first!, end)
        lastEnd = end
        recent.append((write, gap)); if recent.count > 24 { recent.removeFirst() }
    }
    public var description: String {
        let tail = recent.map { String(format: "%.0f/%.0f", $0.write, $0.gap) }.joined(separator: " ")
        return String(format: "writes=%d samples=%d elapsed=%.0fms rate=%.0f/s avgWrite=%.1fms maxWrite=%.1fms maxGap=%.1fms recent(write/gap ms)=[%@]",
                      writes, samples, elapsedMs, effectiveRate, writes > 0 ? totalWriteMs / Double(writes) : 0, maxWriteMs, maxGapMs, tail)
    }
}

extension LaserPoint {
    /// Blanked samples parked at the scanner centre: the idle stream of an
    /// output that has nothing to show. It can never emit light.
    public static func blackCenter(count: Int) -> [LaserPoint] {
        let point = try! LaserPoint(xy: .zero, rgb: .zero, isBlanked: true)
        return Array(repeating: point, count: count)
    }
}

/// Owns one paced sample producer per connected output, keyed by a caller-chosen
/// ID. An idle output streams black (0, 0); a looping pattern can be played over
/// it and removed again. What the pattern depicts, and which outputs exist, is the
/// application's concern.
public actor LaserOutputStreams {
    public typealias Opener = @Sendable () async throws -> any LaserOutputSession
    private struct Stream {
        let session: any LaserOutputSession
        let rate: UInt32
        var task: Task<Void, Never>?
        var generation: UUID
        var looping = false
        var pattern: [LaserPoint] = []
        var offset = 0
        var failure: String?
        var changing = false
        var stats = LaserStreamStats()
    }
    private var streams: [UUID: Stream] = [:]
    private var connecting: Set<UUID> = []
    private let blockSize: Int
    private let pauseNanoseconds: UInt64
    public init(blockSize: Int = 1400, pauseMilliseconds: Int = 20) {
        self.blockSize = blockSize
        self.pauseNanoseconds = UInt64(max(0, pauseMilliseconds)) * 1_000_000
    }

    /// Human-readable state of every stream, served by an app's MCP
    /// `app_diagnostics` tool so a running app can be measured from outside.
    public func diagnosticsReport() -> String {
        guard !streams.isEmpty else { return "no connected output" }
        return streams.map { id, stream in
            "output=\(id) block=\(blockSize) pause=\(pauseNanoseconds / 1_000_000)ms rate=\(stream.rate) looping=\(stream.looping) changing=\(stream.changing) pattern=\(stream.pattern.count) failure=\(stream.failure ?? "none")\n  \(stream.stats)"
        }.sorted().joined(separator: "\n")
    }
    public func diagnostics(_ id: UUID) -> String? { streams[id].map { $0.stats.description } }

    public func hasSession(_ id: UUID) -> Bool { streams[id] != nil }
    /// True while a pattern is looping and the stream has not failed.
    public func patternActive(_ id: UUID) -> Bool { streams[id]?.looping == true && streams[id]?.failure == nil }
    public func streamFailure(_ id: UUID) -> String? { streams[id]?.failure }

    /// Opens a session through `open` and starts streaming black on it.
    public func connect(_ id: UUID, open: Opener) async throws {
        guard streams[id] == nil else { return }
        guard connecting.insert(id).inserted else { throw LaserStreamError.busy }
        defer { connecting.remove(id) }
        let session = try await open()
        let rate = min(session.capabilities.maximumPointRate, 30_000)
        do {
            try await session.start(pointRate: rate)
            let generation = UUID()
            streams[id] = Stream(session: session, rate: rate, task: nil, generation: generation)
            launch(id: id, generation: generation)
        } catch {
            try? await session.disconnect()
            throw error
        }
    }

    /// Streams `pattern` in a loop from its start. An empty pattern streams black.
    public func play(_ pattern: [LaserPoint], for id: UUID) throws {
        guard var stream = streams[id] else { throw LaserStreamError.notConnected }
        guard !stream.changing else { throw LaserStreamError.busy }
        if let failure = stream.failure { throw LaserStreamError.failed(failure) }
        stream.pattern = pattern
        stream.offset = 0
        stream.looping = true
        streams[id] = stream
    }

    /// Swaps the looping pattern without interrupting what is already queued.
    /// Ignored when nothing is looping, so a late replacement cannot revive a
    /// pattern that was stopped meanwhile.
    public func replacePattern(_ pattern: [LaserPoint], for id: UUID) {
        guard var stream = streams[id], stream.looping else { return }
        stream.offset = pattern.isEmpty ? 0 : stream.offset % pattern.count
        stream.pattern = pattern
        streams[id] = stream
    }

    /// Returns to black. Queued pattern samples are interrupted, not played out.
    public func stopPattern(for id: UUID) async throws {
        guard var stream = streams[id] else { throw LaserStreamError.notConnected }
        guard !stream.changing else { throw LaserStreamError.busy }
        if let failure = stream.failure { throw LaserStreamError.failed(failure) }
        guard stream.looping else { return }
        stream.changing = true
        stream.looping = false
        stream.generation = UUID()
        let generation = stream.generation
        let previous = stream.task
        stream.task = nil
        streams[id] = stream
        previous?.cancel()
        do {
            try await stream.session.stop()
            _ = await previous?.result
            guard streams[id]?.generation == generation else { return }
            try await stream.session.start(pointRate: stream.rate)
            guard var current = streams[id], current.generation == generation else {
                try? await stream.session.stop()
                return
            }
            current.changing = false
            current.pattern = []
            current.offset = 0
            streams[id] = current
            launch(id: id, generation: generation)
        } catch {
            if var current = streams[id], current.generation == generation {
                current.changing = false; current.failure = error.localizedDescription; streams[id] = current
            }
            throw error
        }
    }

    public func stopAllPatterns() async {
        for id in Array(streams.keys) where streams[id]?.looping == true {
            try? await stopPattern(for: id)
        }
    }

    public func disconnect(_ id: UUID) async throws {
        guard let stream = streams.removeValue(forKey: id) else { return }
        stream.task?.cancel()
        // Disconnect interrupts an in-flight write and disables output.
        try await stream.session.disconnect()
        _ = await stream.task?.result
    }

    public func disconnectAll() async {
        for id in Array(streams.keys) { try? await disconnect(id) }
    }

    private func launch(id: UUID, generation: UUID) {
        guard var stream = streams[id], stream.generation == generation else { return }
        stream.task = Task { [weak self] in await self?.pump(id: id, generation: generation) }
        streams[id] = stream
    }

    private func pump(id: UUID, generation: UUID) async {
        while !Task.isCancelled {
            guard var stream = streams[id], stream.generation == generation else { return }
            let samples: [LaserPoint]
            if stream.looping && !stream.pattern.isEmpty {
                var block: [LaserPoint] = []
                block.reserveCapacity(blockSize)
                for _ in 0..<blockSize {
                    block.append(stream.pattern[stream.offset])
                    stream.offset = (stream.offset + 1) % stream.pattern.count
                }
                samples = block
            } else {
                samples = LaserPoint.blackCenter(count: blockSize)
            }
            streams[id] = stream
            do {
                let began = DispatchTime.now().uptimeNanoseconds
                try await stream.session.write(samples)
                streams[id]?.stats.record(start: began, end: DispatchTime.now().uptimeNanoseconds, count: samples.count)
                // Real backends apply buffer backpressure. This also keeps mock
                // or exceptionally fast backends from producing a busy loop.
                if pauseNanoseconds > 0 { try await Task.sleep(nanoseconds: pauseNanoseconds) } else { await Task.yield() }
            } catch {
                if Task.isCancelled { return }
                guard var current = streams[id], current.generation == generation else { return }
                current.failure = error.localizedDescription
                current.looping = false
                current.task = nil
                streams[id] = current
                #if DEBUG
                print("LASER_STREAM_FAIL id=\(id) error=\(String(reflecting: error)) looping=\(stream.looping) \(current.stats)")
                #endif
                try? await stream.session.stop()
                return
            }
        }
    }
}
