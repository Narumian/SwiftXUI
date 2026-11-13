import Foundation

public actor LaserOutputConnections {
    public typealias Connector = @Sendable (LaserOutput) async throws -> any LaserOutputSession
    private let streams: LaserOutputStreams
    private let connector: Connector
    private var pendingMasks: [UUID: LaserMaskSettings] = [:]
    private var rebuilding: Set<UUID> = []
    private var manuallyDisconnected: Set<UUID> = []
    private var zones: [UUID: UUID] = [:]
    public init(blockSize: Int = 1400, pauseMilliseconds: Int = 20, connector: @escaping Connector) {
        streams = LaserOutputStreams(blockSize: blockSize, pauseMilliseconds: pauseMilliseconds)
        self.connector = connector
    }

    public func diagnosticsReport() async -> String { await streams.diagnosticsReport() }
    public func diagnostics(_ id: UUID) async -> String? { await streams.diagnostics(id) }

    public func hasSession(_ id: UUID) async -> Bool { await streams.hasSession(id) }
    public func isManuallyDisconnected(_ id: UUID) -> Bool { manuallyDisconnected.contains(id) }
    public func previewEnabled(_ id: UUID) async -> Bool { await streams.patternActive(id) }
    public func streamFailure(_ id: UUID) async -> String? { await streams.streamFailure(id) }

    public func connect(_ output: LaserOutput) async throws {
        manuallyDisconnected.remove(output.id)
        try await open(output)
    }

    public func connectAutomatically(_ output: LaserOutput) async throws {
        guard !manuallyDisconnected.contains(output.id) else { return }
        try await open(output)
    }

    private func open(_ output: LaserOutput) async throws {
        let connector = connector
        try await streams.connect(output.id, masks: output.masks, zone: zones[output.id]) { try await connector(output) }
    }

    public func disconnectForReconfiguration(_ id: UUID) async throws {
        try await streams.disconnect(id)
    }

    public func setPreview(_ enabled: Bool, for id: UUID, masks: LaserMaskSettings) async throws {
        if enabled {
            let pattern = try LaserPreviewPattern.grid(masks: masks)
            pendingMasks[id] = nil
            try await streams.play(pattern, for: id)
        } else {
            try await streams.stopPattern(for: id)
        }
    }

    public func showPattern(_ points: [LaserPoint], for id: UUID) async throws {
        pendingMasks[id] = nil
        try await streams.play(points, for: id)
    }

    public func updatePreviewMasks(_ masks: LaserMaskSettings, for id: UUID) async {
        await streams.setMasks(masks, for: id)
        guard await streams.patternActive(id) else { return }
        pendingMasks[id] = masks
        guard rebuilding.insert(id).inserted else { return }
        Task { await self.rebuildPreview(id) }
    }

    private func rebuildPreview(_ id: UUID) async {
        while let masks = pendingMasks.removeValue(forKey: id) {
            let pattern = try? await Task.detached(priority: .utility) { try LaserPreviewPattern.grid(masks: masks) }.value

            if let pattern { await streams.replacePattern(pattern, for: id) }
        }
        rebuilding.remove(id)
    }

    public func setMasks(_ masks: LaserMaskSettings, for id: UUID) async { await streams.setMasks(masks, for: id) }

    public func play<Stream: Laser2DStream>(_ stream: Stream, zone: UUID = LaserOutputStreams.defaultZone) async throws {
        pendingMasks.removeAll()
        try await streams.play(stream: stream, zone: zone)
    }
    public func play<Source: AsyncSequence & Sendable>(source: Source, sampleRate: UInt32,
                                                        zone: UUID = LaserOutputStreams.defaultZone) async throws
    where Source.Element == [LaserPoint] {
        pendingMasks.removeAll()
        try await streams.play(source: source, sampleRate: sampleRate, zone: zone)
    }

    public func assign(_ id: UUID, to zone: UUID?) async {
        zones[id] = zone
        await streams.assign(id, to: zone)
    }

    public func stopPlaying() async { await streams.stopSource() }

    public func stopPlaying(zone: UUID) async { await streams.stopSource(zone: zone) }

    public func stopPlaying(for id: UUID) async throws { try await streams.stopPattern(for: id) }

    public func zoneOf(_ id: UUID) async -> UUID? { await streams.zone(of: id) }
    public func isPlayingStream(_ id: UUID) async -> Bool { await streams.sourceActive(id) }

    public func disablePreviews() async { await streams.stopAllPatterns() }
    public func disconnect(_ id: UUID) async throws { manuallyDisconnected.insert(id); try await streams.disconnect(id) }
    public func disconnectAll() async { await streams.disconnectAll() }
}
