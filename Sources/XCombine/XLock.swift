import Foundation
#if canImport(os)
import os
#endif

/// A small non-recursive mutex for the thread-crossing types. `os_unfair_lock` where it
/// exists (cheap, and priority-donating, which matters when a real-time-ish producer such as
/// a CoreMIDI callback contends with the owner thread); `NSLock` elsewhere.
///
/// The methods are deliberately not `@inlinable`: callers in other modules reach the lock
/// through one ordinary call, so the `os` import never leaks into inlined code.
@usableFromInline final class _XLock: @unchecked Sendable {
    #if canImport(os)
    private let storage: UnsafeMutablePointer<os_unfair_lock>
    @usableFromInline init() {
        storage = .allocate(capacity: 1)
        storage.initialize(to: os_unfair_lock())
    }
    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }
    @usableFromInline func lock() { os_unfair_lock_lock(storage) }
    @usableFromInline func unlock() { os_unfair_lock_unlock(storage) }
    #else
    private let mutex = NSLock()
    @usableFromInline init() {}
    @usableFromInline func lock() { mutex.lock() }
    @usableFromInline func unlock() { mutex.unlock() }
    #endif
}
