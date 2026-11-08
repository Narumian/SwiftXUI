import Foundation
import XCombine

/// One step of the clock that drives parameters.
public struct LiveClockTick: Sendable, Equatable {
    /// Seconds since the previous step.
    public var deltaTime: Double
    /// Current tempo, for beat-length LFOs. Nil if there is none.
    public var bpm: Double?
    public init(deltaTime: Double, bpm: Double? = nil) { self.deltaTime = deltaTime; self.bpm = bpm }
}

/// Turns an `XTimer` into clock steps. Each subscriber gets its own first step skipped (there is
/// no previous time to measure from), so a parameter that starts listening late never sees a
/// huge first step.
///
///     let clock = LiveClock(timer: XTimer(every: 1.0 / 60), bpm: { tempo.bpm })
public struct LiveClock: XPublisher {
    public typealias Output = LiveClockTick
    public typealias Failure = Never

    private let timer: XTimer
    private let bpm: @Sendable () -> Double?

    public init(timer: XTimer, bpm: @escaping @Sendable () -> Double? = { nil }) {
        self.timer = timer; self.bpm = bpm
    }

    public func receive<S: XSubscriber>(subscriber: S) where S.Input == LiveClockTick, S.Failure == Never {
        var previous: Double?
        let bpm = self.bpm
        timer
            .compactMap { time -> LiveClockTick? in
                defer { previous = time }
                guard let previous else { return nil }
                return LiveClockTick(deltaTime: max(0, time - previous), bpm: bpm())
            }
            .receive(subscriber: subscriber)
    }
}
