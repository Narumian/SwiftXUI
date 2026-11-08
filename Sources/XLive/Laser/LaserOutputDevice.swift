/// How the scanner treats a point. `dwell` holds still on the point so a corner
/// is not rounded off and resampling leaves it alone; `blank` keeps the motion
/// but emits no light. (Same cases and raw values as Legacy's `LSPoint.Mode`.)
public enum LaserPointMode: UInt16, Sendable {
    case normal, dwell, blank
}

/// One sample in scanner space. Each point lasts for 1 / pointRate seconds.
public struct LaserPoint: Equatable, Sendable {
    /// Scanner coordinates in -1...1, with +X right and +Y up.
    public let xy: SIMD2<Float>
    /// RGB drive values in 0...1.
    public let rgb: SIMD3<Float>
    public let mode: LaserPointMode
    /// Suppresses all light output regardless of RGB, while the scanner keeps moving.
    public var isBlanked: Bool { mode == .blank }

    public init(xy: SIMD2<Float>, rgb: SIMD3<Float>, mode: LaserPointMode = .normal) throws {
        guard xy.x.isFinite, xy.y.isFinite,
              (-1...1).contains(xy.x), (-1...1).contains(xy.y),
              rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite,
              (0...1).contains(rgb.x), (0...1).contains(rgb.y), (0...1).contains(rgb.z)
        else { throw LaserOutputError.invalidPoint }
        self.xy = xy; self.rgb = rgb; self.mode = mode
    }

    public init(xy: SIMD2<Float>, rgb: SIMD3<Float>, isBlanked: Bool) throws {
        try self.init(xy: xy, rgb: rgb, mode: isBlanked ? .blank : .normal)
    }

    /// The same place and colour, held still.
    public func dwelling() -> LaserPoint { try! LaserPoint(xy: xy, rgb: rgb, mode: .dwell) }
    /// The same place, dark.
    public func blanked() -> LaserPoint { try! LaserPoint(xy: xy, rgb: .zero, mode: .blank) }
}

public enum LaserOutputError: Error, Equatable, Sendable {
    case invalidPoint
    case unsupportedPointRate
    case notRunning
    case alreadyRunning
    case disconnected
}

/// What one connected output endpoint can do.
public struct LaserOutputCapabilities: Equatable, Sendable {
    /// Upper bound in points per second.
    public let maximumPointRate: UInt32

    public init(maximumPointRate: UInt32) {
        precondition(maximumPointRate > 0)
        self.maximumPointRate = maximumPointRate
    }
}

public enum LaserOutputState: Equatable, Sendable {
    case ready
    case running(pointRate: UInt32)
    /// The message is for display, not for matching.
    case failed(String)
    case disconnected
}

/// A configured output endpoint. Creating one does not connect to hardware.
public protocol LaserOutputDevice: Sendable {
    var id: String { get }
    var name: String { get }
    /// Opens a session with playback stopped and light disabled.
    func connect() async throws -> any LaserOutputSession
}

/// One connection to a device, played by one producer at a time.
public protocol LaserOutputSession: AnyObject, Sendable {
    var capabilities: LaserOutputCapabilities { get }
    /// The current state, then every change.
    var states: AsyncStream<LaserOutputState> { get }
    /// Starts a new timeline at `pointRate`.
    func start(pointRate: UInt32) async throws
    /// Appends samples in order, suspending while the device buffer is full.
    func write(_ points: [LaserPoint]) async throws
    /// Stops playback, disables light and discards queued samples.
    func stop() async throws
    /// Stops and releases the connection.
    func disconnect() async throws
}
