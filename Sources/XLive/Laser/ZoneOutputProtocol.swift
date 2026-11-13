import Foundation

/// What a Zone offers to an output: its shapes, its mastering and the fastest rate it may be sampled at.
/// An output pulls frames with `renderNextFrame`; it knows nothing else of the Zone.
public protocol ZoneSource: Sendable {
    var id: UUID { get }
    var shapes: LaserLive<Laser3DBuffer> { get }
    var mastering: LaserLive<LaserMastering> { get }
    var maximumPointRate: UInt32 { get }
    func renderNextFrame(afterSamples: Int, sampleRate: UInt32) async -> Laser3DBuffer
}

/// Everything an output needs to play a Zone: the source, the scanner settings and the projection that turn its frames
/// into points. It is the only thing that crosses from the Zone to the output.
public struct ZoneDelivery: Sendable {
    public var source: any ZoneSource
    public var scanner: LaserLive<LaserScannerSettings>
    public var projection: LaserProjection

    public init(source: any ZoneSource, scanner: LaserLive<LaserScannerSettings>, projection: LaserProjection) {
        self.source = source; self.scanner = scanner; self.projection = projection
    }

    public var zone: UUID { source.id }
    public var sampleRate: UInt32 { Swift.max(1, source.maximumPointRate) }
}

/// The state of one laser output as the output side sees it.
public struct ZoneOutputStatus: Sendable, Equatable {
    /// A session to the device exists.
    public var connected: Bool
    /// The user disconnected it by hand; automatic connection leaves it alone.
    public var pausedByUser: Bool
    /// The output is playing a Zone's samples.
    public var playing: Bool
    /// The Zone this laser is routed to.
    public var zone: UUID?
    public var failure: String?
    /// Numbers an implementation chooses to report (play position, error, skipped points ...).
    public var metrics: [String: Double]

    public init(connected: Bool = false, pausedByUser: Bool = false, playing: Bool = false, zone: UUID? = nil,
                failure: String? = nil, metrics: [String: Double] = [:]) {
        self.connected = connected; self.pausedByUser = pausedByUser; self.playing = playing
        self.zone = zone; self.failure = failure; self.metrics = metrics
    }
}

/// The one boundary between a Zone and the lasers it drives. Everything downstream of a Zone sits behind it, so a
/// different way of delivering samples replaces the whole of it by changing the type that is made (see `ZoneOutputKind`).
///
/// A laser output belongs to at most one Zone; one Zone may drive several lasers.
public protocol ZoneOutputProtocol: Sendable {
    // Connections. `laser` is a `LaserOutput` id.
    func connect(_ output: LaserOutput, automatic: Bool) async throws
    /// A disconnect by hand: the laser reads as `pausedByUser` afterwards.
    func disconnect(_ laser: UUID) async throws
    func disconnectForReconfiguration(_ laser: UUID) async throws
    func disconnectAll() async

    // Playing and routing.
    /// Starts playing a Zone. Playing a Zone again replaces what it played.
    func play(_ delivery: ZoneDelivery) async throws
    func stop(zone: UUID) async
    /// Sends a laser's light from `zone`; `nil` takes it off every Zone. Routing a laser to a Zone first takes it from
    /// the Zone it was on.
    func route(_ laser: UUID, to zone: UUID?) async

    // Safety masks and the preview pattern, per laser.
    func setMasks(_ masks: LaserMaskSettings, for laser: UUID) async
    func setPreview(_ enabled: Bool, for laser: UUID, masks: LaserMaskSettings) async throws
    func updatePreviewMasks(_ masks: LaserMaskSettings, for laser: UUID) async
    /// Sends `points` to a laser as they are, looping, in place of its Zone and of the preview grid (no masks, no
    /// resampling): for fixed patterns such as the ILDA test pattern when a device is being set up. `setPreview(false…)`
    /// ends it, and the laser goes back to its Zone.
    func showPattern(_ points: [LaserPoint], for laser: UUID) async throws
    /// Ends every preview and stops every playing Zone: all lasers go dark. The application calls it to be sure nothing
    /// is lit when it leaves a project or goes to the background.
    func disablePreviews() async

    // State.
    func status(of laser: UUID) async -> ZoneOutputStatus
    /// A text report for diagnostics.
    func report() async -> String
}

/// Which implementation of `ZoneOutputProtocol` is made. A new way of delivering samples is added as a case and
/// chosen at the one place that makes the output; the previous case stays until the new one has proven itself, so
/// going back is changing the default.
public enum ZoneOutputKind: String, CaseIterable, Sendable {
    /// The current path: one source, a ring and a pump that writes blocks to each device (`LaserOutputConnections`).
    case stream
    /// The zone's clock is the master: a producer, a ring, and for each laser a lane that follows the clock
    /// (`TimeBaseZoneOutput`).
    case timeBase

    public static let `default`: ZoneOutputKind = .timeBase

    /// Makes the output of this kind. `blockSize` is the points per write; `pauseMilliseconds` is the `stream` kind's pause between writes.
    public func make(blockSize: Int = 1400, pauseMilliseconds: Int = 20,
                     connector: @escaping LaserOutputConnections.Connector) -> any ZoneOutputProtocol {
        switch self {
        case .stream:
            return LaserOutputConnections(blockSize: blockSize, pauseMilliseconds: pauseMilliseconds, connector: connector)
        case .timeBase:
            return TimeBaseZoneOutput(settings: .init(blockSize: blockSize), connector: connector)
        }
    }
}
