// What a LiveParameter costs, by input situation and by how many exist.
//
//   swift build -c release --product xlive-bench && .build/release/xlive-bench
//
// Each scenario builds a host with N parameters, drives it for a number of frames (or MIDI
// messages), and reports the median over several runs. "µs/frame" is the whole host for one
// 60 Hz frame (budget: 16 667 µs); "ns/param" divides that by N. Every scenario folds values
// into a checksum so the optimizer cannot discard the work.

import Foundation
import XLive
import XCombine

nonisolated(unsafe) var checksum = 0.0

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) }

func median(runs: Int = 7, _ body: () -> Void) -> Double {
    body()
    var samples: [Double] = []
    for _ in 0..<runs { let t0 = now(); body(); samples.append(now() - t0) }
    samples.sort()
    return samples[samples.count / 2]
}

func makeState(_ i: Int, range: ClosedRange<Double> = 0...1) -> LiveParameterState {
    try! LiveParameterState(id: LiveObjectID(rawValue: "p\(i)"), label: "P\(i)", value: 0.5,
                            mapping: LiveValueMapping(range: range))
}

struct Rig {
    let host: LiveParameterHost
    let params: [LiveParameter]
}

func rig(_ n: Int, configure: (Int, LiveParameter) -> Void = { _, _ in }, host: LiveParameterHost = LiveParameterHost(bpm: 120)) -> Rig {
    let params = (0..<n).map { host.add(makeState($0)) }
    for (i, p) in params.enumerated() { configure(i, p) }
    return Rig(host: host, params: params)
}

let dt = 1.0 / 60

/// Runs `frame` for enough frames that about 200 000 parameter-steps happen, and prints.
let only = ProcessInfo.processInfo.environment["XB_ONLY"]
let repeatFactor = Int(ProcessInfo.processInfo.environment["XB_REPEAT"] ?? "") ?? 1
let onlyN = Int(ProcessInfo.processInfo.environment["XB_N"] ?? "")

func frames(_ name: String, n: Int, _ build: () -> (Rig, () -> Void)) {
    if let only, !name.contains(only) { return }
    if let onlyN, onlyN != n { return }
    let (r, frame) = build()
    let count = max(60, 200_000 / max(1, n)) * repeatFactor
    let total = median {
        for _ in 0..<count { frame() }
    }
    let perFrame = total / Double(count)
    let line = String(format: "%-34@ N=%-5d %10.2f µs/frame %10.1f ns/param", name as NSString, n, perFrame / 1000, perFrame / Double(max(1, n)))
    print(line)
    checksum += r.params.first?.value ?? 0
}

func perMessage(_ name: String, n: Int, messages: Int, _ build: () -> (Rig, (Int) -> Void)) {
    if let only, !name.contains(only) { return }
    if let onlyN, onlyN != n { return }
    let (r, send) = build()
    let total = median { for i in 0..<messages { send(i) } }
    print(String(format: "%-34@ N=%-5d %10.2f µs/message", name as NSString, n, total / Double(messages) / 1000))
    checksum += r.params.first?.value ?? 0
}

print("LiveParameter overhead — frame budget 16667 µs at 60 Hz\n")

for n in [1, 100, 1000] {
    frames("idle (manual, nothing running)", n: n) {
        let r = rig(n)
        return (r, { r.host.advance(seconds: dt) })
    }
    frames("LFO automated", n: n) {
        let r = rig(n) { i, p in
            p.edit { $0.setSource(.lfo); $0.setLFO(try! LiveLFO(period: .beats(Double(1 + i % 8)))); $0.setAutomation(on: true) }
        }
        return (r, { r.host.advance(seconds: dt) })
    }
    frames("LFO + pace reference", n: n) {
        let host = LiveParameterHost(bpm: 120)
        let pace = host.add(makeState(-1))
        let r = rig(n, configure: { _, p in
            p.edit { $0.setSource(.lfo); $0.setPaceReference(pace.id); $0.setAutomation(on: true) }
        }, host: host)
        return (r, { r.host.advance(seconds: dt) })
    }
    frames("audio-follow (shared source)", n: n) {
        let host = LiveParameterHost(bpm: 120)
        let level = XPassthroughSubject<Double, Never>()
        host.provide(.audio(.peak), level.eraseToAnyPublisher())
        let r = rig(n, configure: { _, p in
            p.edit { $0.setSource(.audio(.peak)); $0.setAutomation(on: true) }
        }, host: host)
        var phase = 0.0
        return (r, { phase += 0.05; level.send(0.5 + 0.5 * sin(phase)); r.host.advance(seconds: dt) })
    }
    frames("LFO + a valuePublisher sink each", n: n) {
        let r = rig(n) { _, p in p.edit { $0.setSource(.lfo); $0.setAutomation(on: true) } }
        let sum = r.params.map { p in p.valuePublisher.sink { checksum += $0 } }
        checksum += Double(sum.count)
        return (r, { r.host.advance(seconds: dt) })
    }
    frames("drag one parameter (others idle)", n: n) {
        let r = rig(n)
        var x = 0.0
        return (r, { x = x > 1 ? 0 : x + 0.01; r.params[0].setNormalizedManualValue(x); r.host.advance(seconds: dt) })
    }
    frames("UI read: state+valueText each", n: n) {
        let r = rig(n)
        return (r, {
            for p in r.params { let s = p.state; checksum += s.normalizedValue + Double(s.valueText.utf8.count) }
        })
    }
    frames("UI read: value only", n: n) {
        let r = rig(n)
        return (r, { for p in r.params { checksum += p.value } })
    }
    perMessage("MIDI, hits 1 of N", n: n, messages: 20_000) {
        let r = rig(n) { i, p in
            p.edit { $0.assign(try! LiveMIDIAddress(kind: .control, channel: UInt8((i / 128) % 16), number: UInt8(i % 128))) }
        }
        return (r, { i in r.host.send(.controlChange(channel: 0, controller: UInt8(i % 128), value: UInt8(i % 128))) })
    }
    perMessage("MIDI, hits none", n: n, messages: 20_000) {
        let r = rig(n) { i, p in
            p.edit { $0.assign(try! LiveMIDIAddress(kind: .control, channel: 1, number: UInt8(i % 128))) }
        }
        return (r, { i in r.host.send(.controlChange(channel: 15, controller: UInt8(i % 128), value: 1)) })
    }
    print("")
}

// A busy show: 100 parameters, 20 on LFOs, 10 following audio, 70 idle, and a controller
// sending 8 MIDI messages a frame.
frames("mixed show (20 LFO, 10 audio, 8 MIDI/frame)", n: 100) {
    let host = LiveParameterHost(bpm: 120)
    let level = XPassthroughSubject<Double, Never>()
    host.provide(.audio(.peak), level.eraseToAnyPublisher())
    let r = rig(100, configure: { i, p in
        p.edit {
            if i < 20 { $0.setSource(.lfo); $0.setAutomation(on: true) }
            else if i < 30 { $0.setSource(.audio(.peak)); $0.setAutomation(on: true) }
            $0.assign(try! LiveMIDIAddress(kind: .control, channel: 0, number: UInt8(i)))
        }
    }, host: host)
    var k = 0
    return (r, {
        level.send(Double(k % 100) / 100)
        for j in 0..<8 { r.host.send(.controlChange(channel: 0, controller: UInt8((k + j) % 100), value: UInt8(k % 128))) }
        k += 1
        r.host.advance(seconds: dt)
    })
}
// MARK: Saving and loading

func fullState(_ i: Int) -> LiveParameterState {
    var st = makeState(i, range: 0...127)
    st.setSource(i % 2 == 0 ? .lfo : .audio(.low)); st.setAutomation(on: true)
    st.setLFO(try! LiveLFO(period: .beats(4))); st.setWave(LiveWave(shape: .pwm))
    st.assign(try! LiveMIDIAddress(kind: .control, channel: 1, number: UInt8(i % 128)))
    st.assign(try! LiveMIDIAddress(kind: .note, channel: 2, number: UInt8(i % 128)))
    return st
}

func coding(_ name: String, n: Int, _ make: (Int) -> LiveParameterState) {
    if let only, !name.contains(only) { return }
    if let onlyN, onlyN != n { return }
    let states = (0..<n).map(make)
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    var data = Data()
    let enc = median(runs: 21) { data = try! encoder.encode(states) }
    var back: [LiveParameterState] = []
    let dec = median(runs: 21) { back = try! decoder.decode([LiveParameterState].self, from: data) }
    let plistEncoder = PropertyListEncoder(); plistEncoder.outputFormat = .binary
    var plist = Data()
    let pEnc = median(runs: 21) { plist = try! plistEncoder.encode(states) }
    let pDec = median(runs: 21) { _ = try! PropertyListDecoder().decode([LiveParameterState].self, from: plist) }
    checksum += Double(back.count + data.count)
    print(String(format: "%-26@ N=%-5d JSON enc %8.2f µs/param dec %8.2f µs/param  %5d bytes/param |  plist enc %6.2f dec %6.2f µs  %5d bytes",
                 name as NSString, n, enc / Double(n) / 1000, dec / Double(n) / 1000, data.count / n, pEnc / Double(n) / 1000, pDec / Double(n) / 1000, plist.count / n))
}
print("\nSaving and loading (whole array, per parameter)")
for n in [1, 100, 1000] {
    coding("default parameter", n: n) { makeState($0) }
    coding("fully configured", n: n) { fullState($0) }
}

print("\nchecksum \(checksum)")
