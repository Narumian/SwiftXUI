import Foundation

/// The app's view of its laser outputs: it turns an output's masks into the
/// calibration pattern and hands that to XLive's `LaserOutputStreams`, which owns
/// the sessions and the paced sample pumps.
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

    /// Preview is explicitly enabled by the editor. All grid samples are
    /// filtered by the current mask; normal output remains black at (0, 0).
    public func setPreview(_ enabled: Bool, for id: UUID, masks: LaserMaskSettings) async throws {
        if enabled {
            let pattern = try LaserPreviewPattern.grid(masks: masks)
            pendingMasks[id] = nil
            try await streams.play(pattern, for: id)
        } else {
            try await streams.stopPattern(for: id)
        }
    }

    /// Called while editing. Pointer drags can produce hundreds of updates per
    /// second, so only the latest masks are kept and the grid is rebuilt off
    /// this actor: the sample pump must never wait behind geometry work, or the
    /// device buffer runs dry.
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
            // Masks that cannot be rendered keep the previous pattern.
            if let pattern { await streams.replacePattern(pattern, for: id) }
        }
        rebuilding.remove(id)
    }

    /// Sets the safety masks of an output. They are applied to what the output
    /// plays, after the shared buffer, so they follow the edits while it plays.
    public func setMasks(_ masks: LaserMaskSettings, for id: UUID) async { await streams.setMasks(masks, for: id) }

    /// Plays one scanner stream in a zone at the rate it declares, replacing previews on
    /// the zone's outputs or an earlier stream of the zone. The stream holds everything
    /// that is common to the zone's outputs; each output adds only its rate conversion
    /// and masks.
    public func play<Stream: Laser2DStream>(_ stream: Stream, zone: UUID = LaserOutputStreams.defaultZone) async throws {
        pendingMasks.removeAll()
        try await streams.play(stream: stream, zone: zone)
    }
    /// Moves an output to a zone (the default zone if nil); it joins the zone if that plays.
    /// The choice is kept, so an output that connects later (or again) comes up in its zone.
    public func assign(_ id: UUID, to zone: UUID?) async {
        zones[id] = zone
        await streams.assign(id, to: zone)
    }
    /// Stops the stream; every output returns to black at (0, 0).
    public func stopPlaying() async { await streams.stopSource() }
    /// Stops one zone's stream; its outputs return to black.
    public func stopPlaying(zone: UUID) async { await streams.stopSource(zone: zone) }
    /// Stops whatever is playing on one output; it returns to black at (0, 0).
    public func stopPlaying(for id: UUID) async throws { try await streams.stopPattern(for: id) }
    /// The zone an output is connected in, nil if it is not connected.
    public func zoneOf(_ id: UUID) async -> UUID? { await streams.zone(of: id) }
    public func isPlayingStream(_ id: UUID) async -> Bool { await streams.sourceActive(id) }

    public func disablePreviews() async { await streams.stopAllPatterns() }
    public func disconnect(_ id: UUID) async throws { manuallyDisconnected.insert(id); try await streams.disconnect(id) }
    public func disconnectAll() async { await streams.disconnectAll() }
}
