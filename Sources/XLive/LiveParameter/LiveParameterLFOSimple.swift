import Foundation

/// The simple LFO parameter: a bounded value with an optional sine LFO and a latched manual
/// override. It is driven by `update(context:)` once per host frame.
///
/// Its sibling `LiveParameterMIDISimple` takes its value from MIDI instead.
public struct LiveParameterLFOSimple: Sendable, Codable {
    public enum Mode: String, Equatable, Sendable, Codable { case automatic, manual, returning }
    public let range: ClosedRange<Double>
    public let returnDuration: Double
    public private(set) var value: Double
    public private(set) var manualValue: Double
    public private(set) var mode: Mode
    public private(set) var lfo: LiveLFO?
    private var secondsPhase = 0.0
    private var returnStart = 0.0
    private var returnElapsed = 0.0

    private enum CodingKeys: String, CodingKey {
        case range, returnDuration, value, manualValue, mode, lfo, secondsPhase, returnStart, returnElapsed
    }

    /// Restores a saved parameter through the validating initializer, so a file cannot bring
    /// back a range, value or duration that `init` would refuse. The values that follow are
    /// limited to what they could have been: a value stays in the range, and a phase or a
    /// return stays inside its cycle or duration. Without an LFO the mode is always manual.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lfo = try container.decodeIfPresent(LiveLFO.self, forKey: .lfo)
        try self.init(value: container.decode(Double.self, forKey: .value),
                      range: container.decode(ClosedRange<Double>.self, forKey: .range),
                      lfo: lfo,
                      returnDuration: container.decode(Double.self, forKey: .returnDuration))

        func finite(_ key: CodingKeys) throws -> Double {
            let number = try container.decodeIfPresent(Double.self, forKey: key) ?? 0
            guard number.isFinite else { throw LiveParameterError.invalidValue }
            return number
        }
        manualValue = min(range.upperBound, max(range.lowerBound, try finite(.manualValue)))
        if lfo != nil { mode = try container.decode(Mode.self, forKey: .mode) }
        secondsPhase = min(1, max(0, try finite(.secondsPhase)))
        returnStart = min(range.upperBound, max(range.lowerBound, try finite(.returnStart)))
        returnElapsed = min(returnDuration, max(0, try finite(.returnElapsed)))
    }

    public init(value: Double, range: ClosedRange<Double> = 0...1, lfo: LiveLFO? = nil, returnDuration: Double = 0.3) throws {
        guard range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound < range.upperBound,
              (range.upperBound - range.lowerBound).isFinite else { throw LiveParameterError.invalidRange }
        guard value.isFinite else { throw LiveParameterError.invalidValue }
        guard returnDuration.isFinite, returnDuration >= 0 else { throw LiveParameterError.invalidReturnDuration }
        self.range = range; self.value = min(range.upperBound, max(range.lowerBound, value))
        self.manualValue = self.value; self.lfo = lfo; self.returnDuration = returnDuration
        self.mode = lfo == nil ? .manual : .automatic
    }

    public var normalizedValue: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    /// Dragging takes control immediately and remains latched after the gesture ends.
    public mutating func setManualValue(_ newValue: Double) {
        guard newValue.isFinite else { return }
        value = min(range.upperBound, max(range.lowerBound, newValue))
        manualValue = value; mode = .manual
    }
    public mutating func setNormalizedManualValue(_ normalized: Double) {
        guard normalized.isFinite else { return }
        let clamped = min(1, max(0, normalized))
        setManualValue(range.lowerBound + clamped * (range.upperBound - range.lowerBound))
    }

    /// Tap to release the latch. Without an LFO, the manual value is retained.
    public mutating func releaseManualControl() {
        guard mode == .manual, lfo != nil else { return }
        returnStart = value; returnElapsed = 0; mode = .returning
    }

    public mutating func setLFO(_ lfo: LiveLFO?) {
        self.lfo = lfo
        if lfo == nil { manualValue = value; mode = .manual }
    }

    public mutating func update(context: LiveUpdateContext) {
        guard context.deltaTime.isFinite, context.deltaTime >= 0, let lfo else { return }
        let cycles: Double
        switch lfo.period {
        case .seconds(let period):
            let increment = context.deltaTime / period
            guard increment.isFinite else { return }
            secondsPhase = (secondsPhase + increment.truncatingRemainder(dividingBy: 1)).truncatingRemainder(dividingBy: 1)
            cycles = secondsPhase + lfo.phase
        case .beats(let period):
            guard let tempo = context.tempo, tempo.bpm.isFinite, tempo.bpm > 0, tempo.beatPosition.isFinite else { return }
            let beatCycles = tempo.beatPosition / period
            guard beatCycles.isFinite else { return }
            cycles = beatCycles.truncatingRemainder(dividingBy: 1) + lfo.phase
        }
        let normalized = 0.5 + 0.5 * sin(2 * .pi * cycles.truncatingRemainder(dividingBy: 1))
        let target = range.lowerBound + normalized * (range.upperBound - range.lowerBound)
        switch mode {
        case .automatic: value = target
        case .manual: break
        case .returning:
            returnElapsed = min(returnDuration, returnElapsed + context.deltaTime)
            let progress = returnDuration == 0 ? 1 : returnElapsed / returnDuration
            let smooth = progress * progress * (3 - 2 * progress)
            value = returnStart * (1 - smooth) + target * smooth
            if progress >= 1 { mode = .automatic }
        }
    }
}
