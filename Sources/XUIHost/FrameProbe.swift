import Foundation

/// Where a frame's time went, smoothed over about a second, for a debug readout. The host writes it once per frame; a screen may read it.
public enum FrameProbe {
    /// Milliseconds spent building the view tree and laying it out (the app's update runs before this).
    nonisolated(unsafe) public static var build = 0.0
    /// Milliseconds spent compiling the scene into draw lists.
    nonisolated(unsafe) public static var compile = 0.0
    /// Milliseconds spent encoding and submitting the frame to the GPU (it includes waiting for a drawable).
    nonisolated(unsafe) public static var submit = 0.0
    /// Frames per second drawn.
    nonisolated(unsafe) public static var fps = 0.0
    private nonisolated(unsafe) static var lastEnd = 0.0

    static func record(build: Double, compile: Double, submit: Double) {
        func smooth(_ old: Double, _ new: Double) -> Double { old == 0 ? new : old * 0.9 + new * 0.1 }
        self.build = smooth(self.build, build)
        self.compile = smooth(self.compile, compile)
        self.submit = smooth(self.submit, submit)
        let now = ProcessInfo.processInfo.systemUptime
        if lastEnd > 0, now - lastEnd < 0.5 { fps = smooth(fps, 1 / max(0.001, now - lastEnd)) }
        lastEnd = now
    }

    static var now: Double { ProcessInfo.processInfo.systemUptime * 1000 }

    public static var summary: String {
        String(format: "%.0ffps  build %.1f  compile %.1f  submit %.1f ms", fps, build, compile, submit)
    }
}
