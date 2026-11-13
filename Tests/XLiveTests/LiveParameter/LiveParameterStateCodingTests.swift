import XCTest
import XLive

final class LiveParameterStateCodingTests: XCTestCase {
    private func make(_ configure: (inout LiveParameterState) throws -> Void = { _ in }) throws -> LiveParameterState {
        var s = try LiveParameterState(id: LiveObjectID(rawValue: "p"), label: "P", value: 0.5)
        try configure(&s)
        return s
    }

    private func encoder() -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return e }

    /// Same settings, compared the way a file would show them.
    private func assertSame(_ a: LiveParameterState, _ b: LiveParameterState, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(a.id, b.id, file: file, line: line); XCTAssertEqual(a.label, b.label, file: file, line: line)
        XCTAssertEqual(a.mapping, b.mapping, file: file, line: line)
        XCTAssertEqual(a.value, b.value, file: file, line: line); XCTAssertEqual(a.defaultValue, b.defaultValue, file: file, line: line)
        XCTAssertEqual(a.source, b.source, file: file, line: line)
        XCTAssertEqual(a.automationIsOn, b.automationIsOn, file: file, line: line); XCTAssertEqual(a.inverse, b.inverse, file: file, line: line)
        XCTAssertEqual(a.amount, b.amount, file: file, line: line)
        XCTAssertEqual(a.lfo, b.lfo, file: file, line: line); XCTAssertEqual(a.wave, b.wave, file: file, line: line)
        XCTAssertEqual(a.audioEnvelope.attack, b.audioEnvelope.attack, file: file, line: line)
        XCTAssertEqual(a.audioEnvelope.release, b.audioEnvelope.release, file: file, line: line)
        XCTAssertEqual(a.paceReference, b.paceReference, file: file, line: line)
        XCTAssertEqual(a.pulseWidthReference, b.pulseWidthReference, file: file, line: line)
        XCTAssertEqual(a.midiAddresses, b.midiAddresses, file: file, line: line)
        XCTAssertEqual(try encoder().encode(a), try encoder().encode(b), file: file, line: line)
    }

    private func roundTrip(_ s: LiveParameterState, file: StaticString = #filePath, line: UInt = #line) throws {
        let json = try JSONDecoder().decode(LiveParameterState.self, from: encoder().encode(s))
        try assertSame(s, json, file: file, line: line)
        let plist = PropertyListEncoder(); plist.outputFormat = .binary
        try assertSame(s, PropertyListDecoder().decode(LiveParameterState.self, from: plist.encode(s)), file: file, line: line)
    }

    func testAnUntouchedParameterIsSavedAsAlmostNothing() throws {
        let json = String(decoding: try encoder().encode(try make()), as: UTF8.self)
        XCTAssertEqual(json, #"{"id":"p","label":"P","value":0.5}"#)
        try roundTrip(try make())
        let bare = try JSONDecoder().decode(LiveParameterState.self, from: Data(#"{"id":"x","value":0.25}"#.utf8))
        XCTAssertEqual(bare.value, 0.25); XCTAssertEqual(bare.label, ""); XCTAssertEqual(bare.mapping, try LiveValueMapping())
    }

    func testEveryKindOfSettingSurvivesBothFormats() throws {
        try roundTrip(try make { try $0.setMapping(LiveValueMapping(range: -10...100, limit: 0...50, step: 5)) })
        try roundTrip(try make { try $0.setMapping(LiveValueMapping(range: 0...1, step: 0.25)) })
        try roundTrip(try make { try $0.setMapping(LiveValueMapping(range: 2...8)) })
        try roundTrip(try make { $0.setSource(.lfo); $0.setAutomation(on: true); $0.setInverse(true); $0.setAmount(0.8) })
        try roundTrip(try make { $0.setLFO(try LiveLFO(period: .seconds(2.5), phase: 0.25)) })
        try roundTrip(try make { $0.setLFO(try LiveLFO(period: .beats(1), phase: 0.5)) })
        try roundTrip(try make { $0.setLFO(try LiveLFO(period: .beats(8))) })
        try roundTrip(try make { $0.setWave(LiveWave(shape: .pwm, pulseWidth: 0.3, seed: 42)) })
        try roundTrip(try make { $0.setWave(LiveWave(shape: .random, seed: 7)) })
        try roundTrip(try make { $0.setAudioEnvelope(attack: 0.05, release: 0.4) })
        try roundTrip(try make { $0.setPaceReference(LiveObjectID(rawValue: "q")); $0.setPulseWidthReference(LiveObjectID(rawValue: "r")) })
        try roundTrip(try make { $0.setDefaultValue(0.1) })
        for source: LiveAutomationSource in [.lfo, .audio(.peak), .audio(.low), .motion(.roll), .gamepad(id: "pad:1:left"), .gamepad(id: "")] {
            try roundTrip(try make { $0.setSource(source); $0.setAutomation(on: true) })
        }
        for kind in [LiveMIDIAddress.Kind.control, .note] {
            for channel: UInt8 in [0, 7, 15] {
                for number: UInt8 in [0, 64, 127] {
                    try roundTrip(try make { $0.assign(try LiveMIDIAddress(kind: kind, channel: channel, number: number)) })
                }
            }
        }
        try roundTrip(try make {
            try $0.setMapping(LiveValueMapping(range: 0...127, step: 1))
            $0.setSource(.audio(.high)); $0.setAutomation(on: true)
            $0.assign(try LiveMIDIAddress(kind: .control, channel: 1, number: 3))
            $0.assign(try LiveMIDIAddress(kind: .note, channel: 2, number: 60))
        })
    }

    func testTheEarlierNestedFormStillLoads() throws {
        let old = #"""
        {"id":"p","label":"L","mapping":{"range":[0,127],"step":1},"defaultValue":5,"value":64,
         "source":{"audio":{"_0":"low"}},"automationIsOn":true,"inverse":true,"amount":0.7,
         "lfo":{"period":{"unit":"seconds","length":2},"phase":0.25},
         "wave":{"shape":"pwm","pulseWidth":0.3,"seed":9},
         "audioEnvelope":{"attack":0.05,"release":0.4,"value":0},
         "paceReference":"q","midiAddresses":[{"kind":"note","channel":3,"number":60}]}
        """#
        let s = try JSONDecoder().decode(LiveParameterState.self, from: Data(old.utf8))
        XCTAssertEqual(s.mapping, try LiveValueMapping(range: 0...127, step: 1))
        XCTAssertEqual(s.value, 64); XCTAssertEqual(s.defaultValue, 5)
        XCTAssertEqual(s.source, .audio(.low)); XCTAssertTrue(s.automationIsOn); XCTAssertTrue(s.inverse); XCTAssertEqual(s.amount, 0.7)
        XCTAssertEqual(s.lfo, try LiveLFO(period: .seconds(2), phase: 0.25))
        XCTAssertEqual(s.wave, LiveWave(shape: .pwm, pulseWidth: 0.3, seed: 9))
        XCTAssertEqual(s.audioEnvelope.attack, 0.05)
        XCTAssertEqual(s.paceReference, LiveObjectID(rawValue: "q"))
        XCTAssertEqual(s.midiAddresses, [try LiveMIDIAddress(kind: .note, channel: 3, number: 60)])
        try roundTrip(s)
    }

    func testBadFilesAreRefusedNotTrapped() {
        let bad = [
            #"{"id":"p","value":0.5,"min":10,"max":2}"#,                       // out of order range
            #"{"id":"p","value":0.5,"min":1,"max":1}"#,                        // empty range
            #"{"id":"p","value":0.5,"limitMin":0}"#,                           // half a limit
            #"{"id":"p","value":0.5,"limitMin":9,"limitMax":3}"#,
            #"{"id":"p","value":0.5,"step":0}"#,
            #"{"id":"p","value":0.5,"source":"radio:fm"}"#,
            #"{"id":"p","value":0.5,"source":"audio:loud"}"#,
            #"{"id":"p","value":0.5,"source":""}"#,
            #"{"id":"p","value":0.5,"lfoBeats":1,"lfoSeconds":1}"#,
            #"{"id":"p","value":0.5,"lfoBeats":0}"#,
            #"{"id":"p","value":0.5,"lfoSeconds":-3}"#,
            #"{"id":"p","value":0.5,"waveShape":"zigzag"}"#,
            #"{"id":"p","value":0.5,"midiAddresses":[4096]}"#,
            #"{"id":"p","value":0.5,"midiAddresses":[-1]}"#,
            #"{"id":"p","value":0.5,"midiAddresses":[{"kind":"control","channel":16,"number":1}]}"#,
        ]
        for text in bad {
            XCTAssertThrowsError(try JSONDecoder().decode(LiveParameterState.self, from: Data(text.utf8)), text)
        }
    }

    func testAValueOutsideTheRangeIsPulledInside() throws {
        let s = try JSONDecoder().decode(LiveParameterState.self, from: Data(#"{"id":"p","value":99}"#.utf8))
        XCTAssertEqual(s.value, 1)
    }

    func testAManyParameterFileRoundTrips() throws {
        let states = try (0..<300).map { i in
            try make {
                $0 = try LiveParameterState(id: LiveObjectID(rawValue: "p\(i)"), label: "P\(i)", value: 0.5,
                                            mapping: LiveValueMapping(range: 0...Double(1 + i % 5)))
                if i % 3 == 0 { $0.setSource(.lfo); $0.setAutomation(on: true); $0.setLFO(try LiveLFO(period: .beats(Double(1 + i % 8)))) }
                if i % 4 == 0 { $0.assign(try LiveMIDIAddress(kind: .control, channel: UInt8(i % 16), number: UInt8(i % 128))) }
            }
        }
        let back = try JSONDecoder().decode([LiveParameterState].self, from: encoder().encode(states))
        XCTAssertEqual(back.count, states.count)
        for (a, b) in zip(states, back) { try assertSame(a, b) }
    }

    private func performanceStates(_ count: Int) throws -> [LiveParameterState] {
        try (0..<count).map { i in
            var state = try LiveParameterState(id: LiveObjectID(rawValue: "p\(i)"), label: "P\(i)", value: 0.5,
                                               mapping: LiveValueMapping(range: 0...127))
            state.setSource(i.isMultiple(of: 2) ? .lfo : .audio(.low))
            state.setAutomation(on: true)
            state.setLFO(try LiveLFO(period: .beats(4)))
            state.setWave(LiveWave(shape: .pwm))
            state.assign(try LiveMIDIAddress(kind: .control, channel: 1, number: UInt8(i % 128)))
            state.assign(try LiveMIDIAddress(kind: .note, channel: 2, number: UInt8(i % 128)))
            return state
        }
    }

    func testEncodingOneHundredLiveParametersPerformance() throws {
        let states = try performanceStates(100)
        let encoder = encoder()
        var output = Data()
        measure { output = try! encoder.encode(states) }
        XCTAssertEqual(try JSONDecoder().decode([LiveParameterState].self, from: output).count, 100)
    }

    func testDecodingOneHundredLiveParametersPerformance() throws {
        let data = try encoder().encode(performanceStates(100))
        let decoder = JSONDecoder()
        var decodedCount = 0
        measure { decodedCount = try! decoder.decode([LiveParameterState].self, from: data).count }
        XCTAssertEqual(decodedCount, 100)
    }
}
