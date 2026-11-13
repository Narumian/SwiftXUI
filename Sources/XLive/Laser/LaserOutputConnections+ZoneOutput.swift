import Foundation

/// The `stream` kind of `ZoneOutputProtocol`: the existing connections, pump and ring, behind the boundary.
extension LaserOutputConnections: ZoneOutputProtocol {
    public func connect(_ output: LaserOutput, automatic: Bool) async throws {
        if automatic { try await connectAutomatically(output) } else { try await connect(output) }
    }

    public func play(_ delivery: ZoneDelivery) async throws {
        try await play(source: ZoneSampleStream(delivery), sampleRate: delivery.sampleRate, zone: delivery.zone)
    }

    public func stop(zone: UUID) async { await stopPlaying(zone: zone) }

    public func route(_ laser: UUID, to zone: UUID?) async { await assign(laser, to: zone) }

    public func status(of laser: UUID) async -> ZoneOutputStatus {
        // The pump keeps a laser nobody routed on its default zone; to the boundary that is no Zone.
        let zone = await zoneOf(laser).flatMap { $0 == LaserOutputStreams.defaultZone ? nil : $0 }
        return ZoneOutputStatus(connected: await hasSession(laser), pausedByUser: isManuallyDisconnected(laser),
                         playing: await isPlayingStream(laser), zone: zone,
                         failure: await streamFailure(laser))
    }

    public func report() async -> String { await diagnosticsReport() }
}
