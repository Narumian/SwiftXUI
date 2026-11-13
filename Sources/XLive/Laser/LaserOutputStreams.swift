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

public struct LaserStreamStats: Sendable, CustomStringConvertible {
    public var writes = 0
    public var samples = 0
    public var blankedSamples = 0
    public var maskBlankedSamples = 0
    public var maxWriteMs = 0.0
    public var maxGapMs = 0.0
    public var totalWriteMs = 0.0
    public var elapsedMs = 0.0
    public var recent: [(write: Double, gap: Double)] = []
    var first: UInt64?
    var lastEnd: UInt64?
    public var effectiveRate: Double { elapsedMs > 0 ? Double(samples) / (elapsedMs / 1000) : 0 }
    static func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(to &- from) / 1e6 }
    mutating func record(start: UInt64, end: UInt64, count: Int, blanked: Int, maskBlanked: Int) {
        if first == nil { first = start }
        let write = Self.ms(start, end)
        let gap = lastEnd.map { Self.ms($0, start) } ?? 0
        writes += 1; samples += count; totalWriteMs += write
        blankedSamples += blanked; maskBlankedSamples += maskBlanked
        maxWriteMs = max(maxWriteMs, write); maxGapMs = max(maxGapMs, gap)
        elapsedMs = Self.ms(first!, end)
        lastEnd = end
        recent.append((write, gap)); if recent.count > 24 { recent.removeFirst() }
    }
    public var description: String {
        let tail = recent.map { String(format: "%.0f/%.0f", $0.write, $0.gap) }.joined(separator: " ")
        return String(format: "writes=%d samples=%d blank=%d maskBlank=%d elapsed=%.0fms rate=%.0f/s avgWrite=%.1fms maxWrite=%.1fms maxGap=%.1fms recent(write/gap ms)=[%@]",
                      writes, samples, blankedSamples, maskBlankedSamples, elapsedMs, effectiveRate,
                      writes > 0 ? totalWriteMs / Double(writes) : 0, maxWriteMs, maxGapMs, tail)
    }
}

extension LaserPoint {

    public static func blackCenter(count: Int) -> [LaserPoint] {
        let point = try! LaserPoint(xy: .zero, rgb: .zero, isBlanked: true)
        return Array(repeating: point, count: count)
    }
}

public actor LaserOutputStreams {
    public typealias Opener = @Sendable () async throws -> any LaserOutputSession

    public static let defaultZone = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private final class Tap: @unchecked Sendable {
        let zone: LaserZonePlayback
        let reader: LaserSampleRing.Reader
        var converter: LaserRateConverter
        private var observedSkippedSamples = 0
        private let sourceBlockSize: Int
        init(zone: LaserZonePlayback, outputRate: UInt32, outputBlockSize: Int) {
            self.zone = zone
            let sourceBlockSize = Int(ceil(Double(outputBlockSize) * Double(zone.rate) / Double(outputRate)))
            self.sourceBlockSize = sourceBlockSize
            let maximumLag = max(Int(zone.rate) / 200, sourceBlockSize + 16)
            reader = zone.ring.makeReader(maximumLagSamples: maximumLag)
            converter = LaserRateConverter(sourceRate: zone.rate, outputRate: outputRate)
        }
        func pull(_ count: Int) async throws -> [LaserPoint] {
            let reader = reader
            // A frame is pushed in one piece, so the reader is as far behind as the frame is long: it may lag that much.
            reader.allowLag(atLeast: zone.longestFrame + sourceBlockSize + 16)
            if reader.catchUpIfNeeded() > 0 || reader.skippedSamples != observedSkippedSamples {
                converter.reset()
                observedSkippedSamples = reader.skippedSamples
            }
            let points = try await converter.convertAsync(count: count) { requested in
                try await reader.waitForAvailableLength(atLeast: requested)
                return reader.pull(requested)
            }
            if reader.skippedSamples != observedSkippedSamples {
                converter.reset()
                observedSkippedSamples = reader.skippedSamples
            }
            return points
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

        var zone: UUID?

        var masks = LaserMasking(LaserMaskSettings())
        var pattern: [LaserPoint] = []
        var offset = 0
        var failure: String?
        var changing = false
        var stats = LaserStreamStats()
        var lastProbeLoggedAt: UInt64 = 0
    }
    private var streams: [UUID: Stream] = [:]
    private var zones: [UUID: LaserZonePlayback] = [:]
    private var connecting: Set<UUID> = []
    private let blockSize: Int
    private let pauseNanoseconds: UInt64
    private let sourceBufferSamples: Int
    public init(blockSize: Int = 1400, pauseMilliseconds: Int = 20, sourceBufferSamples: Int? = nil) {
        self.blockSize = blockSize
        self.sourceBufferSamples = max(1, sourceBufferSamples ?? max(1024, 2 * blockSize))
        self.pauseNanoseconds = UInt64(max(0, pauseMilliseconds)) * 1_000_000
    }

    public func diagnosticsReport() -> String {
        guard !streams.isEmpty else { return "no connected output" }
        return streams.map { id, stream in
            "output=\(id) block=\(blockSize) pause=\(pauseNanoseconds / 1_000_000)ms rate=\(stream.rate) looping=\(stream.looping) changing=\(stream.changing) pattern=\(stream.pattern.count) zone=\(stream.zone ?? Self.defaultZone) \(Self.tapReport(stream.tap)) failure=\(stream.failure ?? "none")\n  \(stream.stats)"
        }.sorted().joined(separator: "\n")
    }
    private static func tapReport(_ tap: Tap?) -> String {
        guard let tap else { return "source=none" }
        return "source=\(tap.zone.rate)Hz ring=\(tap.reader.fill)/\(tap.zone.ring.capacity) starved=\(tap.reader.starvedSamples)/\(tap.reader.starvedPullCount)pulls skipped=\(tap.reader.skippedSamples) events=[\(tap.reader.starvationTrace)] sourceFailure=\(tap.zone.failure ?? "none")\n  \(tap.zone.sourceDiagnostics)"
    }
    public func diagnostics(_ id: UUID) -> String? { streams[id].map { $0.stats.description } }

    public func hasSession(_ id: UUID) -> Bool { streams[id] != nil }

    public func patternActive(_ id: UUID) -> Bool { streams[id]?.looping == true && streams[id]?.failure == nil }

    public func sourceActive(_ id: UUID) -> Bool { streams[id]?.tap != nil && streams[id]?.failure == nil }
    public func streamFailure(_ id: UUID) -> String? { streams[id]?.failure }

    public func connect(_ id: UUID, masks: LaserMaskSettings = LaserMaskSettings(), zone: UUID? = nil, open: Opener) async throws {
        guard streams[id] == nil else { return }
        guard connecting.insert(id).inserted else { throw LaserStreamError.busy }
        defer { connecting.remove(id) }
        let session = try await open()
        let rate = min(session.capabilities.maximumPointRate, LaserOutput.playbackRate)
        do {
            try await session.start(pointRate: rate)
            let generation = UUID()
            var stream = Stream(session: session, rate: rate, task: nil, generation: generation)
            stream.masks = LaserMasking(masks)
            stream.zone = zone
            if let playing = zones[zone ?? Self.defaultZone] { stream.tap = Tap(zone: playing, outputRate: rate, outputBlockSize: blockSize) }
            streams[id] = stream
            launch(id: id, generation: generation)
        } catch {
            try? await session.disconnect()
            throw error
        }
    }

    public func play(_ pattern: [LaserPoint], for id: UUID) throws {
        guard var stream = streams[id] else { throw LaserStreamError.notConnected }
        guard !stream.changing else { throw LaserStreamError.busy }
        if let failure = stream.failure { throw LaserStreamError.failed(failure) }
        stream.tap?.detach(); stream.tap = nil
        stream.pattern = pattern
        stream.offset = 0
        stream.looping = true
        stream.generation = UUID()
        let generation = stream.generation
        let previous = stream.task
        stream.task = nil
        streams[id] = stream
        previous?.cancel()
        launch(id: id, generation: generation)
    }

    public func setMasks(_ masks: LaserMaskSettings, for id: UUID) {
        streams[id]?.masks = LaserMasking(masks)
    }

    public func assign(_ id: UUID, to zone: UUID?) {
        guard var stream = streams[id] else { return }
        stream.tap?.detach(); stream.tap = nil
        stream.zone = zone
        if !stream.changing, stream.failure == nil, let playing = zones[zone ?? Self.defaultZone] {
            stream.looping = false
            stream.pattern = []
            stream.tap = Tap(zone: playing, outputRate: stream.rate, outputBlockSize: blockSize)
        }
        stream.generation = UUID()
        let generation = stream.generation
        let previous = stream.task
        stream.task = nil
        streams[id] = stream
        previous?.cancel()
        launch(id: id, generation: generation)
    }

    public func zone(of id: UUID) -> UUID? { streams[id].map { $0.zone ?? Self.defaultZone } }

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
            stream.tap = Tap(zone: next, outputRate: stream.rate, outputBlockSize: blockSize)
            stream.generation = UUID()
            let generation = stream.generation
            let previous = stream.task
            stream.task = nil
            streams[id] = stream
            previous?.cancel()
            launch(id: id, generation: generation)
        }
        next.start(source)
        zones[zoneID] = next
    }

    public func sourceFailure(zone: UUID = LaserOutputStreams.defaultZone) -> String? { zones[zone]?.failure }

    public func replacePattern(_ pattern: [LaserPoint], for id: UUID) {
        guard var stream = streams[id], stream.looping else { return }
        stream.offset = pattern.isEmpty ? 0 : stream.offset % pattern.count
        stream.pattern = pattern
        streams[id] = stream
    }

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

    public func stopSource(zone zoneID: UUID) async {
        zones.removeValue(forKey: zoneID)?.stop()
        for id in Array(streams.keys) where (streams[id]?.zone ?? Self.defaultZone) == zoneID && streams[id]?.tap != nil {
            try? await stopPattern(for: id)
        }
    }

    public func stopSource() async {
        for zoneID in Array(zones.keys) { await stopSource(zone: zoneID) }
    }

    public func disconnect(_ id: UUID) async throws {
        guard let stream = streams.removeValue(forKey: id) else { return }
        stream.tap?.detach()
        stream.task?.cancel()

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
            do {
            let samples: [LaserPoint]
            var blankedBeforeMask = 0
            var maskBlanked = 0
            if let tap = stream.tap {
                let sourceSamples = try await tap.pull(blockSize)
                guard let current = streams[id], current.generation == generation else { return }
                stream = current
                blankedBeforeMask = sourceSamples.reduce(into: 0) { if $1.isBlanked { $0 += 1 } }
                samples = stream.masks.apply(sourceSamples)
                maskBlanked = max(0, samples.reduce(into: 0) { if $1.isBlanked { $0 += 1 } } - blankedBeforeMask)
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
                let began = DispatchTime.now().uptimeNanoseconds
                try await stream.session.write(samples)
                let blanked = samples.reduce(into: 0) { if $1.isBlanked { $0 += 1 } }
                let ended = DispatchTime.now().uptimeNanoseconds
                if var current = streams[id], current.generation == generation {
                    current.stats.record(start: began, end: ended, count: samples.count,
                                         blanked: blanked, maskBlanked: maskBlanked)
                    #if DEBUG
                    if ended &- current.lastProbeLoggedAt >= 1_000_000_000 {
                        current.lastProbeLoggedAt = ended
                        streams[id] = current
                        print("LASER_STREAM_PROBE output=\(id) block=\(blockSize) rate=\(stream.rate) \(current.stats) \(Self.tapReport(current.tap))")
                    } else {
                        streams[id] = current
                    }
                    #else
                    streams[id] = current
                    #endif
                }

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
