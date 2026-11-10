import Foundation

/// Opt-in, low-detail timing for finding expensive XView and layout work.
/// Enable with `XVIEW_PROFILE=1`; normal runs pay only a disabled branch.
enum XViewProfiler {
    private static let sampleEveryFrames = 30
    private struct Metric {
        var calls = 0
        var totalNanoseconds: UInt64 = 0
        var maxNanoseconds: UInt64 = 0
    }

    private struct Scope {
        var type: String
        var startedAt: UInt64
        var childNanoseconds: UInt64 = 0
    }

    private static let enabled: Bool = {
        let value = ProcessInfo.processInfo.environment["XVIEW_PROFILE"] == "1"
        if value { NSLog("XVIEW_PROFILE enabled") }
        return value
    }()
    private nonisolated(unsafe) static var metrics: [String: Metric] = [:]
    private nonisolated(unsafe) static var edgeMetrics: [String: Metric] = [:]
    private nonisolated(unsafe) static var windowStart: UInt64 = 0
    private nonisolated(unsafe) static var lowerScopes: [Scope] = []
    private nonisolated(unsafe) static var measureScopes: [Scope] = []
    private nonisolated(unsafe) static var placeScopes: [Scope] = []
    private nonisolated(unsafe) static var frameNumber = 0
    private nonisolated(unsafe) static var sampledFrames = 0
    private nonisolated(unsafe) static var activeForFrame = false

    static var isEnabled: Bool { activeForFrame }

    static func beginFrame() {
        guard enabled else { return }
        frameNumber += 1
        let now = DispatchTime.now().uptimeNanoseconds
        if windowStart == 0 { windowStart = now }
        activeForFrame = frameNumber.isMultiple(of: sampleEveryFrames)
        if activeForFrame { sampledFrames += 1 }
    }

    @inline(__always)
    static func start() -> UInt64 {
        activeForFrame ? DispatchTime.now().uptimeNanoseconds : 0
    }

    @inline(__always)
    static func record(_ phase: StaticString, type: String, startedAt start: UInt64) {
        guard activeForFrame else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start
        let key = "\(phase)|\(type)"
        var metric = metrics[key, default: Metric()]
        metric.calls += 1
        metric.totalNanoseconds &+= elapsed
        metric.maxNanoseconds = max(metric.maxNanoseconds, elapsed)
        metrics[key] = metric
    }

    @inline(__always)
    static func recordCount(_ phase: StaticString, type: String) {
        guard activeForFrame else { return }
        let key = "\(phase)|\(type)"
        var metric = metrics[key, default: Metric()]
        metric.calls += 1
        metrics[key] = metric
    }

    @inline(__always)
    private static func recordEdge(parent: String, child: String, nanoseconds: UInt64) {
        let key = "measure_edge|\(parent) -> \(child)"
        var metric = edgeMetrics[key, default: Metric()]
        metric.calls += 1
        metric.totalNanoseconds &+= nanoseconds
        metric.maxNanoseconds = max(metric.maxNanoseconds, nanoseconds)
        edgeMetrics[key] = metric
    }

    @inline(__always)
    static func beginLowering() -> UInt64 {
        guard activeForFrame else { return 0 }
        let now = DispatchTime.now().uptimeNanoseconds
        lowerScopes.append(Scope(type: "", startedAt: now))
        return now
    }

    @inline(__always)
    static func endLowering(type: String, startedAt start: UInt64) {
        guard activeForFrame, start != 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let scope = lowerScopes.removeLast()
        let inclusive = now &- scope.startedAt
        record("lower", type: type, startedAt: scope.startedAt &+ scope.childNanoseconds)
        if !lowerScopes.isEmpty { lowerScopes[lowerScopes.count - 1].childNanoseconds &+= inclusive }
    }

    @inline(__always)
    static func beginMeasure(type: String) -> UInt64 {
        guard activeForFrame else { return 0 }
        let now = DispatchTime.now().uptimeNanoseconds
        measureScopes.append(Scope(type: type, startedAt: now))
        return now
    }

    @inline(__always)
    static func endMeasure(startedAt start: UInt64) {
        guard activeForFrame, start != 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let scope = measureScopes.removeLast()
        let inclusive = now &- scope.startedAt
        let selfTime = max(0, inclusive &- scope.childNanoseconds)
        record("measure", type: scope.type, startedAt: scope.startedAt &+ scope.childNanoseconds)
        if let parent = measureScopes.last {
            measureScopes[measureScopes.count - 1].childNanoseconds &+= inclusive
            recordEdge(parent: "measure \(parent.type)", child: scope.type, nanoseconds: selfTime)
        } else if let parent = placeScopes.last {
            placeScopes[placeScopes.count - 1].childNanoseconds &+= inclusive
            recordEdge(parent: "place \(parent.type)", child: scope.type, nanoseconds: selfTime)
        } else {
            recordEdge(parent: "root", child: scope.type, nanoseconds: selfTime)
        }
    }

    @inline(__always)
    static func beginPlacement(type: String) -> UInt64 {
        guard activeForFrame else { return 0 }
        let now = DispatchTime.now().uptimeNanoseconds
        placeScopes.append(Scope(type: type, startedAt: now))
        return now
    }

    @inline(__always)
    static func endPlacement(type: String, startedAt start: UInt64) {
        guard activeForFrame, start != 0 else { return }
        let scope = placeScopes.removeLast()
        record("place", type: type, startedAt: scope.startedAt &+ scope.childNanoseconds)
    }

    /// Called once per completed frame. Nested lowering and measurement scopes
    /// report self-time, so parent calls do not double count their descendants.
    static func finishFrame() {
        guard enabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now &- windowStart
        guard elapsed >= 2_000_000_000 else { return }
        let seconds = Double(elapsed) / 1_000_000_000
        let rows = metrics.map { key, value in (key, value) }
            .sorted { $0.1.totalNanoseconds > $1.1.totalNanoseconds }
        let edgeRows = edgeMetrics.map { key, value in (key, value) }
            .sorted { $0.1.totalNanoseconds > $1.1.totalNanoseconds }
        var lines = [String(format: "XVIEW_PROFILE window_s=%.2f sampled_frames=%d sample_every=%d",
                             seconds, sampledFrames, sampleEveryFrames)]
        var counts: [String: Int] = [:]
        for (key, metric) in rows {
            let phase = key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? "?"
            guard counts[phase, default: 0] < 6 else { continue }
            counts[phase, default: 0] += 1
            let type = key.split(separator: "|", maxSplits: 1).dropFirst().first.map(String.init) ?? "?"
            let totalMS = Double(metric.totalNanoseconds) / 1_000_000
            let averageUS = metric.calls == 0 ? 0 : Double(metric.totalNanoseconds) / Double(metric.calls) / 1_000
            let maxUS = Double(metric.maxNanoseconds) / 1_000
            lines.append(String(format: "  %@ total_ms=%.2f calls=%d avg_us=%.1f max_us=%.1f %@",
                                phase, totalMS, metric.calls, averageUS, maxUS, type))
        }
        for (key, metric) in edgeRows.prefix(10) {
            let edge = key.split(separator: "|", maxSplits: 1).dropFirst().first.map(String.init) ?? "?"
            let totalMS = Double(metric.totalNanoseconds) / 1_000_000
            lines.append(String(format: "  measure_edge total_ms=%.2f calls=%d %@", totalMS, metric.calls, edge))
        }
        NSLog("%@", lines.joined(separator: "\n"))
        metrics.removeAll(keepingCapacity: true)
        edgeMetrics.removeAll(keepingCapacity: true)
        sampledFrames = 0
        windowStart = now
    }
}
