import Foundation

/// A session that can say how many points it holds and has not played yet. With it an output knows where its device
/// is playing (what it wrote less what is still queued) and not only how far it wrote. A session without it is
/// paced by the clock at its nominal rate instead.
public protocol LaserOutputQueueReporting: LaserOutputSession {
    var queuedPoints: Int { get async }
    /// The most the device is kept holding, in points. The zone must be made at least this long ahead of the clock.
    var queueCapacity: Int { get }
}

/// The `timeBase` kind of `ZoneOutputProtocol`. The zone's own clock is the master: a `ZoneProducer` makes the zone's
/// samples at the pace of the clock into a `ZoneRing`, and each laser has a `ZoneLane` that reads the ring at its own
/// rate and follows the clock with a small trim. Lasers of different rates and clocks can play one zone together, and
/// one laser that stalls does not hold back the zone or another laser. A laser that has nothing to play gets dark.
public actor TimeBaseZoneOutput: ZoneOutputProtocol {
    public struct Settings: Sendable, Equatable {
        /// Points per write to a device.
        public var blockSize = 140
        /// How far ahead of the clock a zone is made, in seconds. It has to cover what a device queues.
        public var horizon = 0.25
        /// How much of a zone the ring holds, in seconds.
        public var ringSeconds = 1.0
        public var lane = ZoneLaneSettings()
        public init(blockSize: Int = 140) { self.blockSize = max(1, blockSize) }
    }

    private struct Playing {
        let producer: ZoneProducer
        let rate: UInt32
    }

    private struct Output {
        let session: any LaserOutputSession
        let reporting: (any LaserOutputQueueReporting)?
        let rate: UInt32
        var generation: UUID
        var task: Task<Void, Never>?
        var lane: ZoneLane?
        var masks: LaserMasking
        var pattern: [LaserPoint] = []
        var patternOffset = 0
        var failure: String?
        var writes = 0
        var writtenSamples = 0
    }

    private let settings: Settings
    private let clock: any ZoneClock
    private let connector: LaserOutputConnections.Connector
    private var outputs: [UUID: Output] = [:]
    private var zones: [UUID: Playing] = [:]
    private var routes: [UUID: UUID] = [:]
    private var manuallyDisconnected: Set<UUID> = []
    private var connecting: Set<UUID> = []
    private var rebuilding: Set<UUID> = []
    private var pendingMasks: [UUID: LaserMaskSettings] = [:]

    public init(settings: Settings = Settings(), clock: any ZoneClock = HostZoneClock(),
                connector: @escaping LaserOutputConnections.Connector) {
        self.settings = settings; self.clock = clock; self.connector = connector
    }

    // MARK: Connections

    public func connect(_ output: LaserOutput, automatic: Bool) async throws {
        if automatic { guard !manuallyDisconnected.contains(output.id) else { return } }
        else { manuallyDisconnected.remove(output.id) }
        guard outputs[output.id] == nil else { return }
        guard connecting.insert(output.id).inserted else { throw LaserStreamError.busy }
        defer { connecting.remove(output.id) }
        let session = try await connector(output)
        let rate = min(session.capabilities.maximumPointRate, LaserOutput.playbackRate)
        do { try await session.start(pointRate: rate) } catch { try? await session.disconnect(); throw error }
        let generation = UUID()
        var entry = Output(session: session, reporting: session as? any LaserOutputQueueReporting, rate: rate,
                           generation: generation, masks: LaserMasking(output.masks))
        entry.lane = makeLane(for: output.id, rate: rate)
        outputs[output.id] = entry
        if let reporting = entry.reporting {
            for playing in zones.values { playing.producer.require(horizon: horizon(for: reporting, rate: rate)) }
        }
        launch(output.id, generation: generation)
    }

    public func disconnect(_ laser: UUID) async throws {
        manuallyDisconnected.insert(laser)
        try await remove(laser)
    }

    public func disconnectForReconfiguration(_ laser: UUID) async throws { try await remove(laser) }

    public func disconnectAll() async {
        for id in Array(outputs.keys) { try? await remove(id) }
    }

    private func remove(_ id: UUID) async throws {
        guard let output = outputs.removeValue(forKey: id) else { return }
        output.task?.cancel()
        try await output.session.disconnect()
        _ = await output.task?.result
    }

    // MARK: Playing and routing

    /// How far ahead a zone has to be made for a device that keeps `queueCapacity` points queued: the time they take
    /// to play, a block that is made ahead of being written, and a margin for the clock the pump runs on.
    private func horizon(for session: any LaserOutputQueueReporting, rate: UInt32) -> Double {
        Double(session.queueCapacity + settings.blockSize) / Double(max(1, rate)) + 0.05
    }

    public func play(_ delivery: ZoneDelivery) async throws {
        let rate = delivery.sampleRate
        guard rate > 0 else { throw LaserOutputError.unsupportedPointRate }
        if let previous = zones.removeValue(forKey: delivery.zone) { await previous.producer.stop() }
        // The zone is made far enough ahead for the deepest queue among the devices.
        let needed = outputs.values.compactMap { output in output.reporting.map { horizon(for: $0, rate: output.rate) } }.max() ?? 0
        let producer = ZoneProducer(source: ZoneSampleStream(delivery), rate: rate, clock: clock,
                                    horizon: max(settings.horizon, needed), ringSeconds: settings.ringSeconds)
        await producer.produce(upTo: clock.now + producer.horizon)
        zones[delivery.zone] = Playing(producer: producer, rate: rate)
        await producer.start()
        for id in outputs.keys where routes[id] == delivery.zone { attachLane(id) }
    }

    public func stop(zone: UUID) async {
        guard let playing = zones.removeValue(forKey: zone) else { return }
        await playing.producer.stop()
        for id in outputs.keys where routes[id] == zone { outputs[id]?.lane = nil }
    }

    public func route(_ laser: UUID, to zone: UUID?) async {
        routes[laser] = zone
        guard outputs[laser] != nil else { return }
        outputs[laser]?.lane = nil
        attachLane(laser)
    }

    private func makeLane(for id: UUID, rate: UInt32) -> ZoneLane? {
        guard let zone = routes[id], let playing = zones[zone] else { return nil }
        return ZoneLane(ring: playing.producer.ring, zoneRate: playing.rate, outputRate: rate,
                        epoch: playing.producer.epoch, now: clock.now, settings: settings.lane)
    }

    /// Gives a laser a lane on the zone it is routed to, unless it is showing a preview pattern or has failed.
    private func attachLane(_ id: UUID) {
        guard var output = outputs[id], output.pattern.isEmpty, output.failure == nil else { return }
        output.lane = makeLane(for: id, rate: output.rate)
        outputs[id] = output
    }

    // MARK: Masks and preview

    public func setMasks(_ masks: LaserMaskSettings, for laser: UUID) async {
        outputs[laser]?.masks = LaserMasking(masks)
    }

    public func setPreview(_ enabled: Bool, for laser: UUID, masks: LaserMaskSettings) async throws {
        guard outputs[laser] != nil else { throw LaserStreamError.notConnected }
        if enabled {
            let pattern = try LaserPreviewPattern.grid(masks: masks)
            pendingMasks[laser] = nil
            outputs[laser]?.lane = nil
            outputs[laser]?.pattern = pattern
            outputs[laser]?.patternOffset = 0
        } else {
            endPreview(laser)
        }
    }

    public func showPattern(_ points: [LaserPoint], for laser: UUID) async throws {
        guard outputs[laser] != nil else { throw LaserStreamError.notConnected }
        guard !points.isEmpty else { throw LaserStreamError.failed("The pattern has no points") }
        pendingMasks[laser] = nil
        outputs[laser]?.lane = nil
        outputs[laser]?.pattern = points
        outputs[laser]?.patternOffset = 0
    }

    public func updatePreviewMasks(_ masks: LaserMaskSettings, for laser: UUID) async {
        outputs[laser]?.masks = LaserMasking(masks)
        guard outputs[laser]?.pattern.isEmpty == false else { return }
        pendingMasks[laser] = masks
        guard rebuilding.insert(laser).inserted else { return }
        Task { await self.rebuildPreview(laser) }
    }

    private func rebuildPreview(_ id: UUID) async {
        while let masks = pendingMasks.removeValue(forKey: id) {
            let pattern = try? await Task.detached(priority: .utility) { try LaserPreviewPattern.grid(masks: masks) }.value
            if let pattern, outputs[id]?.pattern.isEmpty == false {
                outputs[id]?.pattern = pattern
                outputs[id]?.patternOffset %= max(1, pattern.count)
            }
        }
        rebuilding.remove(id)
    }

    private func endPreview(_ id: UUID) {
        guard outputs[id]?.pattern.isEmpty == false else { return }
        outputs[id]?.pattern = []
        outputs[id]?.patternOffset = 0
        attachLane(id)
    }

    /// Ends every preview and every playing zone: the outputs go dark. (The application calls it to be sure nothing
    /// is lit when it leaves a project or goes to the background.)
    public func disablePreviews() async {
        for (zone, playing) in zones { await playing.producer.stop(); zones[zone] = nil }
        for id in Array(outputs.keys) {
            outputs[id]?.lane = nil
            outputs[id]?.pattern = []
            outputs[id]?.patternOffset = 0
        }
    }

    // MARK: State

    public func status(of laser: UUID) async -> ZoneOutputStatus {
        let output = outputs[laser]
        var failure = output?.failure
        if failure == nil, let zone = routes[laser], let producer = zones[zone]?.producer { failure = await producer.failure }
        var metrics: [String: Double] = [:]
        if let output {
            metrics["writes"] = Double(output.writes)
            metrics["writtenSamples"] = Double(output.writtenSamples)
            if let lane = output.lane {
                metrics["errorMs"] = lane.errorSeconds * 1000
                metrics["trim"] = lane.trim
                metrics["jumps"] = Double(lane.jumps)
                metrics["skippedSamples"] = Double(lane.skippedSamples + lane.jumpedSamples)
                metrics["underrunSamples"] = Double(lane.underrunSamples)
                metrics["lostSamples"] = Double(lane.lostSamples)
                if let producer = zones[routes[laser] ?? UUID()]?.producer {
                    let made = await producer.stats
                    metrics["frames"] = Double(made.frames)
                    metrics["largestFrame"] = Double(made.largestFrame)
                    metrics["slowestFrameMs"] = made.slowestFrame * 1000
                    metrics["worstLagMs"] = made.worstLag * 1000
                }
            }
        }
        return ZoneOutputStatus(connected: output != nil, pausedByUser: manuallyDisconnected.contains(laser),
                                playing: output?.lane != nil && output?.failure == nil, zone: routes[laser],
                                failure: failure, metrics: metrics)
    }

    public func report() async -> String {
        guard !outputs.isEmpty else { return "no connected output" }
        return outputs.map { id, output in
            var line = "output=\(id) kind=timeBase block=\(settings.blockSize) rate=\(output.rate) zone=\(routes[id]?.uuidString ?? "none")"
            line += " paced=\(output.reporting == nil ? "clock" : "queue") preview=\(!output.pattern.isEmpty) writes=\(output.writes)"
            if let lane = output.lane {
                line += String(format: " errorMs=%.2f trim=%.5f jumps=%d skipped=%d underrun=%d lost=%d", lane.errorSeconds * 1000, lane.trim,
                               lane.jumps, lane.skippedSamples + lane.jumpedSamples, lane.underrunSamples, lane.lostSamples)
            }
            return line + " failure=\(output.failure ?? "none")"
        }.sorted().joined(separator: "\n")
    }

    // MARK: Pump

    private func launch(_ id: UUID, generation: UUID) {
        guard var output = outputs[id], output.generation == generation else { return }
        output.task = Task { [weak self] in await self?.pump(id, generation: generation) }
        outputs[id] = output
    }

    private func pump(_ id: UUID, generation: UUID) async {
        let began = clock.now
        var emitted = 0
        let block = settings.blockSize
        while !Task.isCancelled {
            guard let output = outputs[id], output.generation == generation else { return }
            do {
                // A session that does not report its queue is paced by the clock at its rate: it may run a little ahead.
                if output.reporting == nil {
                    let lead = Int(Double(output.rate) * 0.02) + block
                    let due = began + Double(emitted - lead) / Double(output.rate)
                    if due > clock.now { try await clock.sleep(until: due) }
                }
                let queued = await output.reporting?.queuedPoints
                guard var current = outputs[id], current.generation == generation else { return }
                let now = clock.now
                let samples: [LaserPoint]
                if let lane = current.lane {
                    let held = queued ?? max(0, emitted - Int(((now - began) * Double(current.rate)).rounded()))
                    samples = current.masks.apply(lane.makeBlock(count: block, now: now, queued: held))
                } else if !current.pattern.isEmpty {
                    var points: [LaserPoint] = []
                    points.reserveCapacity(block)
                    for _ in 0..<block {
                        points.append(current.pattern[current.patternOffset])
                        current.patternOffset = (current.patternOffset + 1) % current.pattern.count
                    }
                    outputs[id] = current
                    samples = points
                } else {
                    samples = LaserPoint.blackCenter(count: block)
                }
                try await current.session.write(samples)
                emitted += block
                outputs[id]?.writes += 1
                outputs[id]?.writtenSamples += samples.count
                if output.reporting == nil { await Task.yield() }
            } catch {
                if Task.isCancelled { return }
                guard var current = outputs[id], current.generation == generation else { return }
                current.failure = error.localizedDescription
                current.lane = nil
                current.pattern = []
                current.task = nil
                outputs[id] = current
                try? await current.session.stop()
                return
            }
        }
    }
}
