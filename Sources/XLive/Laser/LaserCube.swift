import Foundation

public enum LaserCubeChannel: Sendable { case command, data }

/// An exclusive unicast connection to one Network LaserCube. Command exchanges are
/// serialized. Sample batches transmit in array order, correlate packet feedback,
/// and must promptly honor cancellation.
/// Command replies carry no transaction IDs. Data feedback echoes the packet
/// sequence, but does not acknowledge individual samples or projected output.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public protocol LaserCubeTransport: AnyObject, Sendable {
    func exchange(_ message: Data, on channel: LaserCubeChannel, timeout: Duration) async throws -> Data
    /// At most 20 packets. Return feedback in matching input order. Backends may
    /// pipeline sends to avoid introducing a network round trip per 140 samples.
    func exchangeSamples(_ packets: [Data], timeout: Duration) async throws -> [Data]
    func close()
}

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public extension LaserCubeTransport {
    /// Correctness fallback for transports without pipelining. Real-time playback
    /// may require a backend override when a packet round trip exceeds 140 / PPS.
    func exchangeSamples(_ packets: [Data], timeout: Duration) async throws -> [Data] {
        var replies: [Data] = []
        for packet in packets { replies.append(try await exchange(packet, on: .data, timeout: timeout)) }
        return replies
    }
}


/// Lightweight timing trace of the LaserCube driver, readable from a host's
/// diagnostics. It answers where a stalled write spent its time and how close
/// the device buffer came to running dry. Cheap enough to leave on.
public enum LaserCubeTrace {
    private struct Tag { var count = 0; var total = 0.0; var max = 0.0 }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tags: [String: Tag] = [:]
    nonisolated(unsafe) private static var slow: [String] = []
    nonisolated(unsafe) private static var minQueued = Int.max
    nonisolated(unsafe) private static var origin = DispatchTime.now().uptimeNanoseconds
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func note(_ tag: String, since start: UInt64, _ detail: @autoclosure () -> String = "") {
        let ms = Double(now() &- start) / 1e6
        lock.withLock {
            var t = tags[tag] ?? Tag(); t.count += 1; t.total += ms; t.max = Swift.max(t.max, ms); tags[tag] = t
            if ms > 40 {
                slow.append(String(format: "%.2fs %@ %.0fms %@", Double(now() &- origin) / 1e9, tag, ms, detail()))
                if slow.count > 40 { slow.removeFirst() }
            }
        }
    }
    static func event(_ message: String) {
        lock.withLock {
            slow.append(String(format: "%.2fs !! %@", Double(now() &- origin) / 1e9, message))
            if slow.count > 40 { slow.removeFirst() }
        }
    }
    static func level(queued: Int) { lock.withLock { minQueued = Swift.min(minQueued, queued) } }
    public static func reset() { lock.withLock { tags = [:]; slow = []; minQueued = .max; origin = now() } }
    public static func report() -> String {
        lock.withLock {
            let rows = tags.sorted { $0.key < $1.key }.map { String(format: "  %@: n=%d avg=%.1fms max=%.1fms", $0.key, $0.value.count, $0.value.total / Double(Swift.max(1, $0.value.count)), $0.value.max) }
            return "lasercube trace (minQueued=\(minQueued == .max ? -1 : minQueued))\n" + rows.joined(separator: "\n") + "\n  events>40ms/last:\n    " + slow.joined(separator: "\n    ")
        }
    }
}

public enum LaserCubeError: Error, Equatable, Sendable {
    case timeout, malformedResponse, operationInProgress, sessionFailed
    case unsupportedProtocol(UInt8)
    case commandRejected(command: UInt8, status: UInt8)
    case configurationNotApplied, outputNotDisabled, underrun, deviceFault
}

/// What the driver does when the device's sample buffer runs dry.
public enum LaserCubeUnderrunPolicy: Sendable {
    /// Report the underrun as a failure, switch the output off and end the session.
    case fail
    /// Count the underrun and keep streaming. The device resumes as soon as data
    /// arrives again, so a brief network stall becomes a momentary gap in the
    /// output instead of a dead session. Hosts must end packets on a blanked
    /// sample so a gap never leaves the beam lit.
    case tolerate
}

/// Driver for the Wi-Fi/Ethernet LaserCube protocol, not the USB LaserCube.
/// The host supplies a fresh exclusive transport for each connection. Apple hosts
/// can import XLiveApple and use init(host:id:name:).
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public struct LaserCube: LaserOutputDevice {
    public let id: String
    public let name: String
    private let makeTransport: @Sendable () async throws -> any LaserCubeTransport
    private let underrunPolicy: LaserCubeUnderrunPolicy

    public init(id: String, name: String = "LaserCube", underrunPolicy: LaserCubeUnderrunPolicy = .fail,
                makeTransport: @escaping @Sendable () async throws -> any LaserCubeTransport) {
        self.id = id; self.name = name; self.underrunPolicy = underrunPolicy; self.makeTransport = makeTransport
    }

    public func connect() async throws -> any LaserOutputSession {
        let transport = try await makeTransport()
        do {
            let info = try LaserCubeWire.info(await transport.exchange(Data([0x77]), on: .command, timeout: .seconds(5)))
            let session = LaserCubeSession(transport: transport, info: info, underrunPolicy: underrunPolicy)
            try await session.prepare()
            return session
        } catch {
            transport.close()
            throw error
        }
    }
}

/// All mutable playback state is actor isolated. The transport owns only bounded
/// packet requests; this driver never makes an unbounded copy or queue of samples.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
private actor LaserCubeSession: LaserOutputSession {
    nonisolated let capabilities: LaserOutputCapabilities
    nonisolated let states: AsyncStream<LaserOutputState>
    private let events: AsyncStream<LaserOutputState>.Continuation
    private let transport: any LaserCubeTransport
    private let initialInfo: LaserCubeInfo
    private enum Mode { case ready, starting, running, stopping, failed, disconnected }
    private var mode = Mode.ready
    private var epoch: UInt64 = 0
    private var operation: Task<Void, any Error>?
    private var shutdown: Task<Void, any Error>?
    private var monitor: Task<Void, Never>?
    private var rate: UInt32 = 0
    private var free: Int
    private var playbackEnabled = false
    private var terminalError: (any Error)?
    private var sequence: UInt8 = 0
    private var frame: UInt8 = 0
    private let clock = ContinuousClock()
    private let underrunPolicy: LaserCubeUnderrunPolicy
    private var emptyReported = false

    init(transport: any LaserCubeTransport, info: LaserCubeInfo, underrunPolicy: LaserCubeUnderrunPolicy) {
        self.transport = transport; self.initialInfo = info; self.free = info.bufferFree
        self.underrunPolicy = underrunPolicy
        capabilities = LaserOutputCapabilities(maximumPointRate: info.maximumPointRate)
        (states, events) = AsyncStream.makeStream()
    }

    deinit {
        operation?.cancel(); shutdown?.cancel(); monitor?.cancel()
        events.finish()
        let connection = transport
        Task {
            // Destruction is only a fallback. Hosts should await disconnect so
            // output-off and buffer-clear are confirmed before releasing ownership.
            _ = try? await connection.exchange(Data([0x80, 0]), on: .command, timeout: .milliseconds(250))
            _ = try? await connection.exchange(Data([0x8d]), on: .command, timeout: .milliseconds(250))
            connection.close()
        }
    }

    func prepare() async throws {
        try await disableAndClear()
        events.yield(.ready)
    }

    func start(pointRate: UInt32) async throws {
        try available()
        guard mode == .ready else { throw LaserOutputError.alreadyRunning }
        guard pointRate > 0, pointRate <= capabilities.maximumPointRate else {
            throw LaserOutputError.unsupportedPointRate
        }
        guard operation == nil, shutdown == nil else { throw LaserCubeError.operationInProgress }
        mode = .starting
        epoch &+= 1
        let token = epoch
        let task = Task { try await self.configure(pointRate: pointRate, token: token) }
        operation = task
        do {
            try await wait(task)
            try check(token)
            operation = nil
            mode = .running
            events.yield(.running(pointRate: pointRate))
        } catch {
            if epoch == token { operation = nil; await fail(error) }
            if let terminalError { throw terminalError }
            throw error
        }
    }

    private func configure(pointRate: UInt32, token: UInt64) async throws {
        try await disableAndClear()
        try check(token)
        try await command(LaserCubeWire.rate(pointRate))
        try check(token)
        try await command(Data([0x78, 1]))
        try check(token)
        let info = try await readInfo()
        try check(token)
        guard info.pointRate == pointRate, !info.outputEnabled else { throw LaserCubeError.configurationNotApplied }
        rate = pointRate
        free = info.bufferFree
        playbackEnabled = false
        // Keep packet counters monotonic across start/stop to reduce the chance of
        // a delayed packet being confused with a new packet by the device.
    }

    func write(_ points: [LaserPoint]) async throws {
        try available()
        guard mode == .running else { throw LaserOutputError.notRunning }
        guard operation == nil, shutdown == nil else { throw LaserCubeError.operationInProgress }
        guard !points.isEmpty else { return }
        let token = epoch
        let task = Task { try await self.send(points, token: token) }
        operation = task
        do {
            try await wait(task)
            try check(token)
            operation = nil
        } catch {
            if epoch == token { operation = nil; await fail(error) }
            if let terminalError { throw terminalError }
            throw error
        }
    }

    // Leave one packet of headroom. On the tested 6000-sample cube this bounds
    // queued playback to 5860 samples (~195 ms at 30 kPPS), absorbing LAN jitter
    // without relying on a larger, unbounded application-side sample queue.
    private var targetFill: Int { max(1, initialInfo.bufferSize - min(140, initialInfo.bufferSize - 1)) }

    private func send(_ points: [LaserPoint], token: UInt64) async throws {
        var offset = 0
        while offset < points.count {
            try check(token)
            var queued = initialInfo.bufferSize - free
            // Keep lookahead within the DAC buffer with one packet of headroom.
            // A burst contains at most 20 packets, matching the vendor SDK limit.
            if queued >= targetFill {
                let deadline = clock.now.advanced(by: .seconds(2))
                repeat {
                    try await clock.sleep(for: .milliseconds(2))
                    try check(token)
                    let began = LaserCubeTrace.now()
                    let reply = try await resilient("wait-credit", token: token) {
                        try await transport.exchange(Data([0x8a]), on: .command, timeout: .seconds(1))
                    }
                    try check(token)
                    free = try LaserCubeWire.bufferFree(reply, capacity: initialInfo.bufferSize)
                    queued = initialInfo.bufferSize - free
                    LaserCubeTrace.note("wait-credit", since: began, "queued=\(queued)")
                    LaserCubeTrace.level(queued: queued)
                    if playbackEnabled, queued == 0 { try underrun("in wait loop") }
                    if clock.now >= deadline { throw LaserCubeError.timeout }
                } while queued >= targetFill
            }
            let count = min(140 * 20, points.count - offset, free, targetFill - queued)
            guard count > 0 else { throw LaserCubeError.malformedResponse }
            var packets: [Data] = []
            var sequences: [UInt8] = []
            var packetOffset = offset
            while packetOffset < offset + count {
                let end = min(packetOffset + 140, offset + count)
                packets.append(LaserCubeWire.samples(points[packetOffset..<end], sequence: sequence, frame: frame))
                sequences.append(sequence)
                sequence &+= 1
                packetOffset = end
            }
            let sendBegan = LaserCubeTrace.now()
            let replies = try await resilient("samples", token: token) {
                try await transport.exchangeSamples(packets, timeout: .seconds(1))
            }
            LaserCubeTrace.note("samples", since: sendBegan, "packets=\(packets.count) queuedBefore=\(queued)")
            try check(token)
            guard replies.count == packets.count else { throw LaserCubeError.malformedResponse }
            for (reply, sequence) in zip(replies, sequences) {
                _ = try LaserCubeWire.bufferFree(reply, capacity: initialInfo.bufferSize, sequence: sequence)
            }
            // All packet replies have arrived. Query fresh credit only now, rather
            // than treating out-of-order packet snapshots as current buffer space.
            let creditBegan = LaserCubeTrace.now()
            let credit = try await resilient("credit", token: token) {
                try await transport.exchange(Data([0x8a]), on: .command, timeout: .seconds(1))
            }
            try check(token)
            free = try LaserCubeWire.bufferFree(credit, capacity: initialInfo.bufferSize)
            LaserCubeTrace.note("credit", since: creditBegan, "queued=\(initialInfo.bufferSize - free)")
            LaserCubeTrace.level(queued: initialInfo.bufferSize - free)
            if free == initialInfo.bufferSize { try underrun("after send (free=\(free))") } else { emptyReported = false }
            offset += count
            // The wire frame counter follows a network burst, as in the vendor
            // SDK. A large write must not reuse a sequence/frame pair when its
            // eight-bit packet counter wraps.
            frame &+= 1
            if !playbackEnabled {
                // Real WiFi Cube FW 0.12 automatically enables playback as soon
                // as sample data arrives, even after SET_OUTPUT(0). Its DAC also
                // consumes those samples immediately. An OFF-state prefill would
                // discard the beginning of the producer's timeline while waiting
                // for a fill level that may never be reached.
                playbackEnabled = true
                startMonitor(token: token)
            }
        }
    }

    func stop() async throws {
        try available()
        if let shutdown { return try await wait(shutdown) }
        if mode == .ready { return }
        mode = .stopping
        epoch &+= 1
        let token = epoch
        let oldOperation = operation
        let oldMonitor = monitor
        oldOperation?.cancel(); oldMonitor?.cancel()
        operation = nil; monitor = nil
        let task = Task {
            // Transport cancellation releases any pending receive promptly, so stop
            // never waits for a producer's flow-control or sample supply.
            if let oldOperation { _ = await oldOperation.result }
            if let oldMonitor { await oldMonitor.value }
            try Task.checkCancellation()
            try await self.disableAndClear()
        }
        shutdown = task
        do {
            try await wait(task)
            try check(token)
            shutdown = nil
            playbackEnabled = false
            mode = .ready
            events.yield(.ready)
        } catch {
            if epoch == token { shutdown = nil; await fail(error) }
            throw error
        }
    }

    func disconnect() async throws {
        if mode == .disconnected { return }
        var stopError: (any Error)?
        if mode != .failed {
            do { try await stop() } catch { stopError = error }
        }
        epoch &+= 1
        operation?.cancel(); monitor?.cancel(); shutdown?.cancel()
        operation = nil; monitor = nil; shutdown = nil
        transport.close()
        mode = .disconnected
        events.yield(.disconnected)
        events.finish()
        if let stopError { throw stopError }
    }

    private func startMonitor(token: UInt64) {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(25))
                    guard let self else { return }
                    try await self.inspectPlayback(token: token)
                } catch is CancellationError { return }
                catch LaserCubeError.timeout where self?.underrunPolicy == .tolerate {
                    LaserCubeTrace.event("monitor timeout tolerated")
                    LaserCubeTrace.note("timeout-tolerated", since: LaserCubeTrace.now())
                    continue
                }
                catch {
                    await self?.monitorFailed(error, token: token)
                    return
                }
            }
        }
    }

    private func inspectPlayback(token: UInt64) async throws {
        try check(token)
        let began = LaserCubeTrace.now()
        let info = try await readInfo()
        try check(token)
        LaserCubeTrace.note("monitor-info", since: began, "queued=\(info.bufferSize - info.bufferFree)")
        guard info.outputEnabled, info.pointRate == rate else { throw LaserCubeError.configurationNotApplied }
        if info.bufferFree == info.bufferSize { try underrun("seen by monitor") } else { emptyReported = false }
        // Do not overwrite the data-channel credit with an uncorrelated command
        // snapshot while a packet is in flight.
    }

    /// Under `.tolerate` a UDP exchange that gets no reply in time is retried a few
    /// times instead of ending the session: the link does stall for around a second
    /// now and then, and the device simply resumes once data arrives again.
    private func resilient<T>(_ site: String, token: UInt64, _ body: () async throws -> T) async throws -> T {
        var attempts = 0
        while true {
            do { return try await body() }
            catch LaserCubeError.timeout where underrunPolicy == .tolerate && attempts < 5 {
                attempts += 1
                LaserCubeTrace.event("timeout tolerated at \(site) (attempt \(attempts))")
                LaserCubeTrace.note("timeout-tolerated", since: LaserCubeTrace.now())
                try check(token)
            }
        }
    }

    /// A dry device buffer. Fatal under `.fail`; under `.tolerate` it is counted
    /// (once per episode) and streaming continues.
    private func underrun(_ place: String) throws {
        LaserCubeTrace.event("UNDERRUN \(place)")
        if underrunPolicy == .fail { throw LaserCubeError.underrun }
        if !emptyReported { emptyReported = true; LaserCubeTrace.note("underrun-tolerated", since: LaserCubeTrace.now()) }
    }

    private func monitorFailed(_ error: any Error, token: UInt64) async {
        guard epoch == token, mode == .running else { return }
        terminalError = error
        epoch &+= 1
        let old = operation
        operation = nil
        old?.cancel()
        if let old { _ = await old.result }
        await fail(error)
    }

    private func fail(_ error: any Error) async {
        guard mode != .disconnected, mode != .failed else { return }
        mode = .failed
        terminalError = error
        epoch &+= 1
        monitor?.cancel(); monitor = nil
        events.yield(.failed(String(describing: error)))
        events.finish()
        // Best effort only: UDP or a disconnected cable cannot confirm darkness.
        // Cleanup runs in its own task so a cancelled producer does not cancel
        // output-off before it has even been sent.
        let connection = transport
        let cleanup = Task {
            _ = try? await connection.exchange(Data([0x80, 0]), on: .command, timeout: .milliseconds(250))
            _ = try? await connection.exchange(Data([0x8d]), on: .command, timeout: .milliseconds(250))
            connection.close()
        }
        await cleanup.value
    }

    private func disableAndClear() async throws {
        try await command(Data([0x80, 0]))
        try await command(Data([0x8d]))
        let info = try await readInfo()
        guard !info.outputEnabled, info.bufferFree == info.bufferSize else { throw LaserCubeError.outputNotDisabled }
        free = info.bufferFree
        playbackEnabled = false
    }

    private func command(_ bytes: Data) async throws {
        try Task.checkCancellation()
        try LaserCubeWire.success(await transport.exchange(bytes, on: .command, timeout: .seconds(1)), command: bytes[0])
    }

    private func readInfo() async throws -> LaserCubeInfo {
        let info = try LaserCubeWire.info(await transport.exchange(Data([0x77]), on: .command, timeout: .seconds(1)))
        guard info.bufferSize == initialInfo.bufferSize, info.maximumPointRate == capabilities.maximumPointRate else {
            throw LaserCubeError.configurationNotApplied
        }
        if info.overTemperature { throw LaserCubeError.deviceFault }
        return info
    }

    private func available() throws {
        if mode == .disconnected { throw LaserOutputError.disconnected }
        if mode == .failed { throw LaserCubeError.sessionFailed }
    }

    private func check(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard epoch == token else { throw CancellationError() }
        try available()
    }

    private func wait(_ task: Task<Void, any Error>) async throws {
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

struct LaserCubeInfo: Sendable {
    let pointRate: UInt32
    let maximumPointRate: UInt32
    let bufferFree: Int
    let bufferSize: Int
    let outputEnabled: Bool
    let overTemperature: Bool
}

/// Wire layout checked against Wicked Lasers' LaserDockNetworkDevice.cpp, protocol
/// version 0. Byte reads deliberately avoid aligned/native-endian pointer loads.
enum LaserCubeWire {
    static func success(_ data: Data, command: UInt8) throws {
        guard data.count >= 2, data.first == command else { throw LaserCubeError.malformedResponse }
        guard data[data.startIndex + 1] == 0 else {
            throw LaserCubeError.commandRejected(command: command, status: data[data.startIndex + 1])
        }
    }

    static func info(_ data: Data) throws -> LaserCubeInfo {
        try success(data, command: 0x77)
        let bytes = Array(data)
        guard bytes.count == 64 else { throw LaserCubeError.malformedResponse }
        guard bytes[2] == 0 else { throw LaserCubeError.unsupportedProtocol(bytes[2]) }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
        let capacity = u16(21), free = u16(19), maximum = u32(14)
        guard capacity > 0, free <= capacity, maximum > 0 else { throw LaserCubeError.malformedResponse }
        let modernFlags = bytes[3] > 0 || bytes[4] >= 13
        return LaserCubeInfo(pointRate: u32(10), maximumPointRate: maximum,
                             bufferFree: free, bufferSize: capacity, outputEnabled: bytes[5] & 1 != 0,
                             overTemperature: bytes[5] & (modernFlags ? 8 : 32) != 0)
    }

    static func bufferFree(_ data: Data, capacity: Int, sequence: UInt8? = nil) throws -> Int {
        let bytes = Array(data)
        guard bytes.count == 4, bytes[0] == 0x8a else { throw LaserCubeError.malformedResponse }
        if let sequence {
            // Data feedback byte 1 echoes packet sequence. Unlike a command
            // response, a nonzero byte here is not a command failure.
            guard bytes[1] == sequence else { throw LaserCubeError.malformedResponse }
        } else {
            try success(data, command: 0x8a)
        }
        let free = Int(bytes[2]) | Int(bytes[3]) << 8
        guard free <= capacity else { throw LaserCubeError.malformedResponse }
        return free
    }

    static func rate(_ value: UInt32) -> Data {
        Data([0x82, UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
              UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
    }

    static func samples(_ points: ArraySlice<LaserPoint>, sequence: UInt8, frame: UInt8) -> Data {
        var result = Data([0xa9, 0, sequence, frame])
        result.reserveCapacity(4 + points.count * 10)
        func append(_ value: Float) {
            let sample = UInt16(min(1, max(0, value)) * 4095)
            result.append(UInt8(truncatingIfNeeded: sample))
            result.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        for point in points {
            // Match Legacy's default X orientation. The former hard-coded 0.95
            // scan scale belongs in output calibration, not the wire encoder.
            append((1 - point.xy.x) / 2)
            append((point.xy.y + 1) / 2)
            let color = point.isBlanked ? SIMD3<Float>.zero : point.rgb
            append(color.x); append(color.y); append(color.z)
        }
        return result
    }
}
