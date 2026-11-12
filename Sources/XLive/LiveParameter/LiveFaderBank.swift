import Foundation
import XCombine

/// What the bank did with a MIDI message.
public enum LiveFaderReception: Equatable, Sendable {
    /// Not for any fader, or nothing to do with it.
    case ignored
    /// A fader has the address; it was assigned and learning ended. The target did not move.
    case learned(slot: Int, LiveMIDIAddress)
    /// The slot's target now has the value the fader says.
    case applied(slot: Int)
    /// The fader is not on the target's value yet (pickup); nothing moved.
    case waiting(slot: Int)
    /// The target is automated, so the fader has no effect.
    case locked(slot: Int)
}

/// A fixed row of faders that act on whatever the host points them at: the same eight MIDI
/// controls can drive the parameters of one node, then of another. The bank knows nothing about
/// what a slot means; the host says which parameter each slot drives (`setTargets`).
///
/// A fader is a MIDI CC, or an on-screen slider that calls `move`. The on-screen slider shows
/// the target's own value (`LiveParameter.state.normalizedValue`) and writes it directly, so it
/// never needs to wait. A MIDI fader goes through pickup (`LiveTakeover`, the mode of the
/// environment's `midiTakeover`): after the target changes, or something else moves its value, the
/// fader does nothing until it reaches the value, so switching targets never makes it jump.
///
/// A fader writes with `setNormalizedManualValue`, like a hand on the target's own slider. A
/// target that is automated is locked: the fader has no effect and `isLocked` says so.
///
/// Only the addresses are worth keeping; positions and targets are runtime state. It belongs to
/// one thread or actor, like the parameters it drives.
public final class LiveFaderBank: @unchecked Sendable {
    public let count: Int
    /// The MIDI controller of each slot, if any. Controllers only; a note is not a fader.
    public private(set) var addresses: [LiveMIDIAddress?]
    /// The slot waiting for a controller to be moved, if any.
    public private(set) var learningSlot: Int?
    public private(set) weak var environment: (any LiveParameterEnvironment)?

    private var targets: [LiveParameter?]
    private var takeovers: [LiveTakeover]
    /// The target's value as this bank last wrote it; if it differs, something else moved it.
    private var written: [Double?]
    private var addressTokens: [XAnyCancellable] = []
    private var allMIDIToken: XAnyCancellable?
    private var routedAddresses: [LiveMIDIAddress]?

    public init(count: Int, environment: (any LiveParameterEnvironment)? = nil) {
        self.count = max(0, count)
        addresses = Array(repeating: nil, count: self.count)
        targets = Array(repeating: nil, count: self.count)
        takeovers = Array(repeating: LiveTakeover(), count: self.count)
        written = Array(repeating: nil, count: self.count)
        self.environment = environment
        reconcileMIDI()
    }

    deinit { allMIDIToken = nil; addressTokens = [] }

    /// Connects the bank to a host.
    public func attach(to environment: any LiveParameterEnvironment) {
        addressTokens = []; allMIDIToken = nil; routedAddresses = nil
        self.environment = environment
        reconcileMIDI()
    }

    // MARK: Targets

    /// Points the slots at parameters, slot by slot; slots past the end of the list, and nil
    /// entries, drive nothing. A slot whose parameter changed has to be picked up again.
    public func setTargets(_ parameters: [LiveParameter?]) {
        for slot in 0..<count {
            let next = slot < parameters.count ? parameters[slot] : nil
            if targets[slot] !== next {
                targets[slot] = next
                takeovers[slot].release(); written[slot] = nil
            }
        }
    }

    public func target(_ slot: Int) -> LiveParameter? { isSlot(slot) ? targets[slot] : nil }

    /// The target is automated: the fader has no effect.
    public func isLocked(_ slot: Int) -> Bool { target(slot)?.state.isAutomated ?? false }

    /// Where the MIDI controller last was, 0...1, or nil before it was first moved.
    public func controlPosition(_ slot: Int) -> Double? { isSlot(slot) ? takeovers[slot].position : nil }

    /// What the slot's label shows: nothing assigned, a controller assigned, or waiting for one to move.
    public func midiState(_ slot: Int) -> LiveMIDIState {
        guard isSlot(slot) else { return .none }
        if learningSlot == slot { return .learning }
        return addresses[slot] == nil ? .none : .assigned
    }

    /// A moved controller that does not hold the target's value yet: it has to reach it first.
    public func isWaiting(_ slot: Int) -> Bool {
        guard isSlot(slot), let target = targets[slot], let position = takeovers[slot].position,
              addresses[slot] != nil, takeovers[slot].engaged == nil else { return false }
        return abs(position - target.state.normalizedValue) > target.state.takeoverTolerance
    }

    // MARK: On-screen fader

    /// The on-screen fader moved to `normalized` (0...1). It sets the value at once.
    public func move(_ slot: Int, to normalized: Double) {
        guard isSlot(slot), let target = targets[slot], !target.state.isAutomated, normalized.isFinite else { return }
        write(slot, target, min(1, max(0, normalized)))
        // The hand now holds the value: a controller has to come back to it.
        takeovers[slot].release()
    }

    // MARK: MIDI

    /// Gives the slot a controller; the controller is taken from any other slot.
    public func assign(_ address: LiveMIDIAddress, to slot: Int) {
        guard isSlot(slot), address.kind == .control else { return }
        for other in 0..<count where addresses[other] == address { addresses[other] = nil; takeovers[other] = LiveTakeover() }
        addresses[slot] = address; takeovers[slot] = LiveTakeover()
        reconcileMIDI()
    }

    public func unassign(_ slot: Int) {
        guard isSlot(slot), addresses[slot] != nil else { return }
        addresses[slot] = nil; takeovers[slot] = LiveTakeover()
        if learningSlot == slot { learningSlot = nil }
        reconcileMIDI()
    }

    /// The next controller that moves is assigned to this slot.
    public func beginLearning(_ slot: Int) {
        guard isSlot(slot) else { return }
        learningSlot = slot
        reconcileMIDI()
    }

    public func cancelLearning() {
        learningSlot = nil
        reconcileMIDI()
    }

    @discardableResult
    public func receive(_ message: MIDIMessage) -> LiveFaderReception {
        if let slot = learningSlot {
            guard let learned = LiveMIDIAddress(learning: message), learned.kind == .control else { return .ignored }
            learningSlot = nil
            assign(learned, to: slot)
            return .learned(slot: slot, learned)
        }
        for slot in 0..<count {
            guard let address = addresses[slot], let raw = address.value(in: message) else { continue }
            let position = Double(raw) / 127
            guard let target = targets[slot] else {
                // Keep the controller's position, so the first target is picked up from it.
                _ = takeovers[slot].accepts(position, from: address, current: position)
                return .ignored
            }
            // Something else moved the value since this bank wrote it: the controller lost it.
            if let last = written[slot], last != target.value { takeovers[slot].release(); written[slot] = nil }
            let state = target.state
            let reached = takeovers[slot].accepts(position, from: address, current: state.normalizedValue,
                                                  tolerance: state.takeoverTolerance)
            if state.isAutomated { return .locked(slot: slot) }
            guard reached || environment?.midiTakeover == .jump else { return .waiting(slot: slot) }
            write(slot, target, position)
            takeovers[slot].engage(address)
            return .applied(slot: slot)
        }
        return .ignored
    }

    // MARK: Wiring

    private func isSlot(_ slot: Int) -> Bool { slot >= 0 && slot < count }

    private func write(_ slot: Int, _ target: LiveParameter, _ normalized: Double) {
        target.setNormalizedManualValue(normalized)
        written[slot] = target.value
    }

    /// Listens to each assigned controller through the host's route, and to the whole stream only
    /// while learning or when the host cannot route.
    private func reconcileMIDI() {
        guard let environment else { addressTokens = []; allMIDIToken = nil; routedAddresses = nil; return }
        let wanted = addresses.compactMap { $0 }
        var needsAll = learningSlot != nil
        if wanted != routedAddresses {
            addressTokens = []; routedAddresses = wanted
            for address in wanted {
                if let route = environment.midi(for: address) {
                    addressTokens.append(route.sink { [weak self] message in
                        if self?.learningSlot == nil { self?.receive(message) }
                    })
                } else {
                    needsAll = true
                }
            }
        } else if wanted.contains(where: { environment.midi(for: $0) == nil }) {
            needsAll = true
        }
        if needsAll {
            if allMIDIToken == nil { allMIDIToken = environment.midi.sink { [weak self] message in self?.receive(message) } }
        } else {
            allMIDIToken = nil
        }
    }
}
