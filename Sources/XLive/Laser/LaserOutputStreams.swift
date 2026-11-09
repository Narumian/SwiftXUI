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

/// Owns one paced sample pump per connected output, keyed by a caller-chosen ID, and
/// the zones that play on them. An idle output streams black (0, 0); a looping pattern
/// can be played over it and removed again; a live source is played in a zone, and every
/// output that belongs to the zone plays it. An output belongs to one zone: the one it
/// was assigned, or the default zone. What the pattern depicts, which outputs exist and
/// which zone each is in is the application's concern.
public actor LaserOutputStreams {
    public typealias Opener = @Sendable () async throws -> any LaserOutputSession

    /// The id of the zone an output belongs to until it is assigned another.
    public static let defaultZone = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// One output's way of playing its zone: its own reader on the zone's ring, and the
    /// rate converter from the zone's rate to the device's. Only the pump touches the
    /// converter.
    private final class Tap: @unchecked Sendable {
        let zone: LaserZonePlayback
        let reader: LaserSampleRing.Reader
        var converter: LaserRateConverter
        init(zone: LaserZonePlayback, outputRate: UInt32) {
            self.zone = zone
            reader = zone.ring.makeReader()
            converter = LaserRateConverter(sourceRate: zone.rate, outputRate: outputRate)
        }
        func pull(_ count: Int) -> [LaserPoint] {
            let reader = reader
            return converter.convert(count: count) { reader.pull($0) }
        }
        func detach() { zone.ring.remove(reader) }
    }

    private struct Stream {
        let session: any LaserOutputSession
        let rate: UInt32
        var task: Task<Void, Never>?
        var generation: UUID
        var looping = false
        var tap: Tap?
        /// The zone this output was assigned; nil means the default zone.
        var zone: UUID?
        /// The output's own safety masks, applied to the live source after the ring.
        var masks = LaserMasking(LaserMaskSettings())
        var pattern: [LaserPoint] = []
        var offset = 0
        var failure: String?
        var changing = false
        var stats = LaserStreamStats()
    }
    private var streams: [UUID: Stream] = [:]
    private var zones: [UUID: LaserZonePlayback] = [:]
    private var connecting: Set<UUID> = []
    private let blockSize: Int
    private let pauseNanoseconds: UInt64
    private let sourceBufferSamples: Int
    /// `sourceBufferSamples` bounds the ring of each zone between its source and the pumps; the
    /// default of two blocks keeps edits within roughly a block of the output.
    public init(blockSize: Int = 1400, pauseMilliseconds: Int = 20, sourceBufferSamples: Int? = nil) {
        self.blockSize = blockSize
        self.sourceBufferSamples = max(1, sourceBufferSamples ?? 2 * blockSize)
        self.pauseNanoseconds = UInt64(max(0, pauseMilliseconds)) * 1_000_000
    }

    /// Human-readable state of every stream, served by an app's MCP
    /// `app_diagnostics` tool so a running app can be measured from outside.
    public func diagnosticsReport() -> String {
        guard !streams.isEmpty else { return "no connected output" }
        return streams.map { id, stream in
            "output=\(id) block=\(blockSize) pause=\(pauseNanoseconds / 1_000_000)ms rate=\(stream.rate) looping=\(stream.looping) changing=\(stream.changing) pattern=\(stream.pattern.count) zone=\(stream.zone ?? Self.defaultZone) \(Self.tapReport(stream.tap)) failure=\(stream.failure ?? "none")\n  \(stream.stats)"
        }.sorted().joined(separator: "\n")
    }
    private static func tapReport(_ tap: Tap?) -> String {
        guard let tap else { return "source=none" }
        return "source=\(tap.zone.rate)Hz ring=\(tap.reader.fill)/\(tap.zone.ring.capacity) starved=\(tap.reader.starvedSamples)/\(tap.reader.starvedPullCount)pulls skipped=\(tap.reader.skippedSamples) sourceFailure=\(tap.zone.failure ?? "none")"
    }
    public func diagnostics(_ id: UUID) -> String? { streams[id].map { $0.stats.description } }

    public func hasSession(_ id: UUID) -> Bool { streams[id] != nil }
    /// True while a pattern is looping and the stream has not failed.
    public func patternActive(_ id: UUID) -> Bool { streams[id]?.looping == true && streams[id]?.failure == nil }
    /// True while a live source is attached and the stream has not failed.
    public func sourceActive(_ id: UUID) -> Bool { streams[id]?.tap != nil && streams[id]?.failure == nil }
    public func streamFailure(_ id: UUID) -> String? { streams[id]?.failure }

    /// Opens a session through `open` and starts streaming black on it, or its zone if
    /// that is playing. `masks` are the output's safety masks; `zone` is the zone the
    /// output belongs to (the default zone if nil).
    public func connect(_ id: UUID, masks: LaserMaskSettings = LaserMaskSettings(), zone: UUID? = nil, open: Opener) async throws {
        guard streams[id] == nil else { return }
        guard connecting.insert(id).inserted else { throw LaserStreamError.busy }
        defer { connecting.remove(id) }
        let session = try await open()
        let rate = min(session.capabilities.maximumPointRate, 30_000)
        do {
            try await session.start(pointRate: rate)
            let generation = UUID()
            var stream = Stream(session: session, rate: rate, task: nil, generation: generation)
            stream.masks = LaserMasking(masks)
            stream.zone = zone
            if let playing = zones[zone ?? Self.defaultZone] { stream.tap = Tap(zone: playing, outputRate: rate) }
            streams[id] = stream
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
        stream.tap?.detach(); stream.tap = nil
        stream.pattern = pattern
        stream.offset = 0
        stream.looping = true
        streams[id] = stream
    }

    /// Sets the safety masks of one output. They apply to the live source from the
    /// next block, so they can be edited while it plays.
    public func setMasks(_ masks: LaserMaskSettings, for id: UUID) {
        streams[id]?.masks = LaserMasking(masks)
    }

    /// Moves an output to a zone (the default zone if nil). If that zone is playing, the
    /// output joins it at once; if it is not, what the output was playing from its old
    /// zone stops and it streams black.
    public func assign(_ id: UUID, to zone: UUID?) {
        guard var stream = streams[id] else { return }
        stream.tap?.detach(); stream.tap = nil
        stream.zone = zone
        if !stream.changing, stream.failure == nil, let playing = zones[zone ?? Self.defaultZone] {
            stream.looping = false
            stream.pattern = []
            stream.tap = Tap(zone: playing, outputRate: stream.rate)
        }
        streams[id] = stream
    }

    /// The zone an output belongs to, nil if it is not connected.
    public func zone(of id: UUID) -> UUID? { streams[id].map { $0.zone ?? Self.defaultZone } }

    /// Plays a live source of sample chunks recorded at `sampleRate` in a zone, replacing
    /// any pattern on its outputs and the zone's earlier source. The zone has one source
    /// and one ring; each of its outputs reads the ring on its own clock through its own
    /// rate converter and applies its own masks. The source is pulled at its own pace and
    /// suspends when the ring is full, so a slow source cannot stall a pump: the outputs
    /// go dark meanwhile, and a stalled output loses its place without holding up the
    /// others. Chunks need no particular size. An output that connects, or is assigned,
    /// while the zone plays joins it. Other zones are not touched.
    public func play<Source: AsyncSequence & Sendable>(source: Source, sampleRate: UInt32, zone zoneID: UUID = LaserOutputStreams.defaultZone) throws
    where Source.Element == [LaserPoint] {
        guard sampleRate > 0 else { throw LaserOutputError.unsupportedPointRate }
        for id in Array(streams.keys) where (streams[id]?.zone ?? Self.defaultZone) == zoneID {
            streams[id]?.tap?.detach(); streams[id]?.tap = nil
        }
        zones[zoneID]?.stop()
        let next = LaserZonePlayback(id: zoneID, rate: sampleRate, bufferSamples: sourceBufferSamples)
        for (id, var stream) in streams where (stream.zone ?? Self.defaultZone) == zoneID && !stream.changing && stream.failure == nil {
            stream.looping = false
            stream.pattern = []
            stream.tap = Tap(zone: next, outputRate: stream.rate)
            streams[id] = stream
        }
        next.start(source)
        zones[zoneID] = next
    }

    /// The failure that ended a zone's source, if it ended on one.
    public func sourceFailure(zone: UUID = LaserOutputStreams.defaultZone) -> String? { zones[zone]?.failure }

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
        guard stream.looping || stream.tap != nil else { return }
        stream.tap?.detach(); stream.tap = nil
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
        for zone in zones.values { zone.stop() }
        zones.removeAll()
        for id in Array(streams.keys) where streams[id]?.looping == true || streams[id]?.tap != nil {
            try? await stopPattern(for: id)
        }
    }

    /// Stops one zone's source; its outputs return to black.
    public func stopSource(zone zoneID: UUID) async {
        zones.removeValue(forKey: zoneID)?.stop()
        for id in Array(streams.keys) where (streams[id]?.zone ?? Self.defaultZone) == zoneID && streams[id]?.tap != nil {
            try? await stopPattern(for: id)
        }
    }

    /// Stops every zone's source; every output returns to black.
    public func stopSource() async {
        for zoneID in Array(zones.keys) { await stopSource(zone: zoneID) }
    }

    public func disconnect(_ id: UUID) async throws {
        guard let stream = streams.removeValue(forKey: id) else { return }
        stream.tap?.detach()
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
            if let tap = stream.tap {
                samples = stream.masks.apply(tap.pull(blockSize))
            } else if stream.looping && !stream.pattern.isEmpty {
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
                current.tap?.detach(); current.tap = nil
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
