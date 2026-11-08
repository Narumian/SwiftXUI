/// One sample in an already mapped and resampled scanner timeline.
/// Each point lasts for 1 / pointRate seconds. Dwell is represented by repeated
/// points; blank travel must also include the samples needed to move the scanner.
public struct LaserPoint: Equatable, Sendable {
    /// Normalized scanner coordinates in -1...1, with +X right and +Y up.
    public let xy: SIMD2<Float>
    /// Normalized RGB drive values in 0...1, after output color correction.
    public let rgb: SIMD3<Float>
    /// Suppresses all light output, regardless of RGB, while retaining XY motion.
    public let isBlanked: Bool

    public init(xy: SIMD2<Float>, rgb: SIMD3<Float>, isBlanked: Bool = false) throws {
        guard xy.x.isFinite, xy.y.isFinite,
              (-1...1).contains(xy.x), (-1...1).contains(xy.y),
              rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite,
              (0...1).contains(rgb.x), (0...1).contains(rgb.y), (0...1).contains(rgb.z)
        else { throw LaserOutputError.invalidPoint }
        self.xy = xy; self.rgb = rgb; self.isBlanked = isBlanked
    }
}

public enum LaserOutputError: Error, Equatable, Sendable {
    case invalidPoint
    case unsupportedPointRate
    case notRunning
    case alreadyRunning
    case disconnected
}

/// Capabilities of one connected output endpoint, rather than the transport host.
public struct LaserOutputCapabilities: Equatable, Sendable {
    /// Upper bound in points per second. Start may reject unsupported rates below
    /// this limit as well; it must not silently substitute a different rate.
    public let maximumPointRate: UInt32

    public init(maximumPointRate: UInt32) {
        precondition(maximumPointRate > 0)
        self.maximumPointRate = maximumPointRate
    }
}

public enum LaserOutputState: Equatable, Sendable {
    /// Connected, with playback stopped and light output disabled.
    case ready
    /// Accepts samples for playback at this rate. Actual playback may begin after
    /// the backend has buffered the first samples.
    case running(pointRate: UInt32)
    /// A terminal backend failure. The message is for display, not error matching.
    case failed(String)
    case disconnected
}

/// A configured output endpoint. A host with multiple outputs exposes one device
/// per endpoint. Construction does not connect to hardware or enable light output.
/// Discovery and transport-specific addressing belong to backend implementations.
///
/// Logical outputs, source selection, mapping regions, and device assignments are
/// owned by the application. Rebinding a logical output to another device keeps
/// its mapping independent of this device's identity and transport.
public protocol LaserOutputDevice: Sendable {
    /// Backend-defined endpoint identity, independent of its display name. Prefer
    /// hardware identity plus channel when available; this is not a logical output ID.
    var id: String { get }
    var name: String { get }

    /// Establishes an exclusive session with playback stopped and light disabled.
    /// A failed connection must release any resources acquired during the attempt.
    func connect() async throws -> any LaserOutputSession
}

/// One independently paced connection. One producer serially calls start/write;
/// separate devices have separate sessions and must not share a blocking send loop.
/// Shared transport connections are an implementation detail of the backend.
///
/// Input is a continuous timeline of scanner samples, not shapes or drawing frames.
/// Mapping, clipping, region transitions, resampling, dwell, blanking paths, and
/// output calibration happen upstream. The backend converts coordinate conventions
/// and numeric formats, packetizes samples, and manages device buffer flow control.
/// Sessions do not promise synchronized playback across devices.
public protocol LaserOutputSession: AnyObject, Sendable {
    var capabilities: LaserOutputCapabilities { get }

    /// One consumer observes the current state followed by state changes. Initially
    /// ready; disconnect ends the stream after yielding disconnected. A terminal
    /// backend failure yields failed and ends the stream; disconnect still releases
    /// resources. Never silently reconnect or resume playback after a failure.
    var states: AsyncStream<LaserOutputState> { get }

    /// Starts a new timeline at a positive, supported rate. Only valid when ready.
    /// An invalid rate throws unsupportedPointRate; a running session throws
    /// alreadyRunning. Playback may wait for the first write to prefill its buffer.
    func start(pointRate: UInt32) async throws

    /// Appends samples in order, exactly once on success. Empty input is a no-op
    /// while running; calls outside running throw notRunning or disconnected.
    ///
    /// Completion means the backend accepted the block, not that it was projected.
    /// Backends must bound their pending buffers and suspend the producer when full;
    /// never silently drop or reorder samples. Block boundaries have no drawing or
    /// packet meaning.
    ///
    /// An underrun, where the device runs out of samples, is not a failure. Links
    /// such as Wi-Fi stall briefly and routinely, and the device resumes as soon as
    /// samples arrive again, so the session keeps running and the gap is only a
    /// momentary lapse in the output. Backends count underruns and expose them for
    /// diagnostics instead of ending the timeline. A backend must not fill a gap
    /// itself by repeating old content or holding a lit point. The producer is
    /// responsible for safety across gaps: it ends every packet-sized run on a
    /// blanked sample, so a stalled device never rests on a lit point.
    ///
    /// Cancellation or transport failure may occur after partial acceptance, so
    /// callers must not automatically retry a failed block. Such a failure ends
    /// this timeline, disables output where communication permits, and is terminal.
    func write(_ points: [LaserPoint]) async throws

    /// Stops playback, disables light, and discards pending samples before returning
    /// to ready. Idempotent when ready. Must interrupt a suspended write; stopping
    /// cannot wait for an indefinitely blocked producer. A stop failure is terminal
    /// and must be reported, rather than claiming the device is ready.
    func stop() async throws

    /// Attempts to stop output and always releases connection resources, even if
    /// stopping fails. Idempotent after disconnection. Interrupts pending operations;
    /// samples from the old timeline must not leak into a subsequent session.
    func disconnect() async throws
}
