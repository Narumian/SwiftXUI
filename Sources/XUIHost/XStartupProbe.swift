import Foundation

/// Lightweight DEBUG-only timing marks for application boot and resource
/// preparation. The probe is framework-owned so platform shells and apps can
/// use the same timestamp format without depending on AppKit or UIKit.
public final class XStartupProbe: @unchecked Sendable {
    private let label: String
    private let startedAt: UInt64
    private let lock = NSLock()

    public init(_ label: String) {
        self.label = label
        self.startedAt = DispatchTime.now().uptimeNanoseconds
    }

    public func mark(_ event: String, detail: String? = nil) {
        #if DEBUG
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        let suffix = detail.map { " \($0)" } ?? ""
        lock.lock()
        defer { lock.unlock() }
        let line = String(format: "[%@ +%.1fms] %@%@\n", label, elapsed, event, suffix)
        FileHandle.standardError.write(Data(line.utf8))
        #endif
    }
}
