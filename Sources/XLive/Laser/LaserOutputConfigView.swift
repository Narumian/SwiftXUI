import Foundation
import XUI

private let outputBackground = XColorValue(hex: 0x171b1c)
private let outputPanel = XColorValue(hex: 0x252b2a)
private let outputText = XColorValue(hex: 0xe6eeea)
private let outputMuted = XColorValue(hex: 0xa5b4ac)
private let outputAccent = XColorValue(hex: 0x86d1b5)

public struct LaserOutputConfigView: XView, Sendable {
    private var _collection: StateStore.Box<LaserOutputCollection>?
    private var _selectedID: StateStore.Box<UUID?>?
    private var _editingMasks: StateStore.Box<Bool>?
    private var _editingScanner: StateStore.Box<Bool>?
    private var _detailVisible: StateStore.Box<Bool>?
    private var _editingAddress: StateStore.Box<Bool>?
    private var _addressDraft: StateStore.Box<String>?
    private var _addressError: StateStore.Box<Bool>?
    private var _connectionStates: StateStore.Box<[UUID: String]>?
    private var _statusPolling: StateStore.Box<Bool>?
    private var _testPattern: StateStore.Box<[UUID: String]>?
    private var _testPower: StateStore.Box<Int>?
    private var _testNote: StateStore.Box<[UUID: String]>?
    private var collection: LaserOutputCollection { _collection?.value ?? initialOutputs }
    private var selectedID: UUID? { _selectedID?.value ?? nil }
    private var editingMasks: Bool { _editingMasks?.value ?? false }
    private var editingScanner: Bool { _editingScanner?.value ?? false }
    private var detailVisible: Bool { _detailVisible?.value ?? false }
    private var editingAddress: Bool { _editingAddress?.value ?? false }
    private var addressDraft: String { _addressDraft?.value ?? "" }
    private var addressError: Bool { _addressError?.value ?? false }
    private var connectionStates: [UUID: String] { _connectionStates?.value ?? [:] }
    /// The test pattern each output is showing (absent: none), its brightness in percent, and what went wrong.
    private var testPattern: [UUID: String] { _testPattern?.value ?? [:] }
    private var testPower: Int { _testPower?.value ?? 10 }
    private var testNote: [UUID: String] { _testNote?.value ?? [:] }
    public mutating func _installState(id: StateIdentity, store: StateStore) {
        _collection = store._xstateBox(id: id, name: "collection", default: { initialOutputs })
        _selectedID = store._xstateBox(id: id, name: "selectedID", default: { nil })
        _editingMasks = store._xstateBox(id: id, name: "editingMasks", default: { false })
        _editingScanner = store._xstateBox(id: id, name: "editingScanner", default: { false })
        _detailVisible = store._xstateBox(id: id, name: "detailVisible", default: { false })
        _editingAddress = store._xstateBox(id: id, name: "editingAddress", default: { false })
        _addressDraft = store._xstateBox(id: id, name: "addressDraft", default: { "" })
        _addressError = store._xstateBox(id: id, name: "addressError", default: { false })
        _connectionStates = store._xstateBox(id: id, name: "connectionStates", default: { [:] })
        _statusPolling = store._xstateBox(id: id, name: "statusPolling", default: { false })
        _testPattern = store._xstateBox(id: id, name: "testPattern", default: { [:] })
        _testPower = store._xstateBox(id: id, name: "testPower", default: { 10 })
        _testNote = store._xstateBox(id: id, name: "testNote", default: { [:] })
        if let shown = _testPattern, let connections {
            // Leaving this screen darkens what it lit: a test pattern is shown only while it is in front of the person.
            shown.onRemove = { _ in
                let active = Array(shown.value.keys)
                guard !active.isEmpty else { return }
                Task { for id in active { try? await connections.setPreview(false, for: id, masks: .init()) } }
            }
        }
        if let polling = _statusPolling, !polling.value, let statuses = _connectionStates, let collection = _collection, let connections {
            polling.value = true
            polling.onRemove = { _ in polling.value = false }
            let invalidate = invalidate
            Task { @XUIActor in
                while polling.value, !Task.isCancelled {
                    var next: [UUID: String] = [:]
                    for item in collection.value.outputs where item.device == .laserCube && LaserOutput.isValidIPv4(item.address) {
                        let state = await connections.status(of: item.id)
                        next[item.id] = state.failure.map { "FAILED: \($0)" } ?? (state.connected ? "CONNECTED" : (state.pausedByUser ? "NOT CONNECTED" : "AUTO CONNECTING"))
                    }
                    if next != statuses.value { statuses.value = next; invalidate() }
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                }
            }
        }
    }
    let initialOutputs: LaserOutputCollection
    let onChange: @Sendable (LaserOutputCollection) -> Void
    let connections: (any ZoneOutputProtocol)?
    let invalidate: @Sendable () -> Void
    public init(initialOutputs: LaserOutputCollection = .init(), onChange: @escaping @Sendable (LaserOutputCollection) -> Void = { _ in }, connections: (any ZoneOutputProtocol)? = nil, invalidate: @escaping @Sendable () -> Void = {}) {
        self.initialOutputs = initialOutputs; self.onChange = onChange
        self.connections = connections; self.invalidate = invalidate
    }

    public var body: some XView {
        let items = collection.outputs
        let selected = items.first { $0.id == selectedID }
        let state = _collection, selection = _selectedID, masksPage = _editingMasks, scannerPage = _editingScanner
        let statuses = _connectionStates
        let detail = _detailVisible, addressPage = _editingAddress, draft = _addressDraft, error = _addressError
        if editingMasks, let selected {
            LaserMaskEditor(initialSettings: selected.masks, outputName: selected.name,
                            hasConnection: connectionStates[selected.id] == "CONNECTED",
                            connections: connections, outputID: selected.id, invalidate: invalidate, onSave: { masks in
                guard let state else { return }
                var next = state.value
                next.updateMasks(masks, for: selected.id)
                state.value = next
                onChange(next)
                if let connections {
                    Task { await connections.updatePreviewMasks(masks, for: selected.id) }
                }
            }, onBack: { masksPage?.value = false })
        } else if editingScanner {
            LaserScannerSettingsView(initial: collection.scanner, onChange: { settings in
                guard let state else { return }
                var next = state.value
                next.scanner = settings
                state.value = next
                onChange(next)
            }, onBack: { scannerPage?.value = false })
        } else {
            GeometryReader { geometry in
                let wide = geometry.width >= 650 && geometry.width > geometry.height
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        if !wide && detailVisible {
                            button("‹ OUTPUTS") { detail?.value = false; addressPage?.value = false }
                        }
                        Text("TRIDENT  /  LASER OUTPUTS", size: 16, color: outputText)
                        Spacer()
                        Text("CONFIG", size: 11, color: outputMuted)
                    }.padding(12).background { Rectangle(fill: outputPanel) }
                    if wide {
                        HStack(alignment: .top, spacing: 0) {
                            ScrollView(id: "laser.outputs.list") {
                                outputList(items, selectedID: selectedID, states: connectionStates, state: state, selection: selection, detail: detail, addressPage: addressPage, scannerPage: scannerPage)
                            }.frame(width: .pt(230))
                            ScrollView(id: "laser.outputs.detail") {
                                outputDetail(selected, state: state, masksPage: masksPage, addressPage: addressPage, draft: draft, error: error,
                                             isEditingAddress: editingAddress, addressText: addressDraft, addressInvalid: addressError, status: selected.flatMap { connectionStates[$0.id] } ?? "NOT CONNECTED", statuses: statuses)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if detailVisible, let selected {
                        ScrollView(id: "laser.outputs.detail.narrow") {
                            outputDetail(selected, state: state, masksPage: masksPage, addressPage: addressPage, draft: draft, error: error,
                                         isEditingAddress: editingAddress, addressText: addressDraft, addressInvalid: addressError, status: connectionStates[selected.id] ?? "NOT CONNECTED", statuses: statuses)
                        }
                    } else {
                        ScrollView(id: "laser.outputs.list.narrow") {
                            outputList(items, selectedID: selectedID, states: connectionStates, state: state, selection: selection, detail: detail, addressPage: addressPage, scannerPage: scannerPage)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background { Rectangle(fill: outputBackground) }
            }
        }
    }

    private func outputList(_ items: [LaserOutput], selectedID: UUID?, states: [UUID: String], state: StateStore.Box<LaserOutputCollection>?,
                            selection: StateStore.Box<UUID?>?, detail: StateStore.Box<Bool>?, addressPage: StateStore.Box<Bool>?,
                            scannerPage: StateStore.Box<Bool>?) -> some XView {
        VStack(alignment: .leading, spacing: 9) {
            Text("ALL OUTPUTS", size: 12, color: outputMuted)
            button("SCANNER SETTINGS   ›") { Task { await stopTestPatterns() }; scannerPage?.value = true }
            Text("OUTPUTS", size: 12, color: outputMuted)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name, size: 15, color: outputText)
                    Text(item.device == .laserCube ? "LASERCUBE · \(states[item.id] ?? "NOT CONNECTED")" : "UNASSIGNED", size: 10, color: outputMuted)
                }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background { RoundedRectangle(cornerRadius: 5, fill: item.id == selectedID ? XColorValue(hex: 0x354b42) : outputPanel) }
                    .onTapGesture(id: "output.select.\(item.id)", label: item.name) {
                        Task { await stopTestPatterns() }
                        selection?.value = item.id; detail?.value = true; addressPage?.value = false
                        if let connections {
                            let statuses = _connectionStates
                            Task { @XUIActor in
                                let state = await connections.status(of: item.id)
                                setStatus(statuses, item.id, state.failure.map { "FAILED: \($0)" } ?? (state.connected ? "CONNECTED" : "NOT CONNECTED"))
                                invalidate()
                            }
                        }
                    }
            }
            button("+ CREATE OUTPUT") {
                guard let state else { return }
                var next = state.value
                let name = String(format: "Laser %02d", next.outputs.count + 1)
                let item = LaserOutput(name: name)
                next.outputs.append(item)
                state.value = next; selection?.value = item.id; detail?.value = true; addressPage?.value = false
                onChange(next)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading).background { Rectangle(fill: outputPanel) }
    }

    private func outputDetail(_ output: LaserOutput?, state: StateStore.Box<LaserOutputCollection>?, masksPage: StateStore.Box<Bool>?,
                              addressPage: StateStore.Box<Bool>?, draft: StateStore.Box<String>?, error: StateStore.Box<Bool>?,
                              isEditingAddress: Bool, addressText: String, addressInvalid: Bool, status: String, statuses: StateStore.Box<[UUID: String]>?) -> some XView {
        VStack(alignment: .leading, spacing: 12) {
            if let output {
                Text(output.name, size: 20, color: outputText)
                Text("LASER OUTPUT  ·  \(status)", size: 11, color: outputMuted)
                Text("OUTPUT DEVICE", size: 12, color: outputMuted)
                if status == "CONNECTED" || status == "CONNECTING" || status == "DISCONNECTING" {
                    Text(output.device == .laserCube ? "LASERCUBE  ·  \(output.address)" : "UNASSIGNED", size: 12, color: outputMuted)
                } else {
                HStack(spacing: 8) {
                    button(output.device == .unassigned ? "● UNASSIGNED" : "○ UNASSIGNED") { updateOutput(state, output.id, onChange: onChange) { $0.device = .unassigned } }
                    button(output.device == .laserCube ? "● LASERCUBE" : "○ LASERCUBE") { updateOutput(state, output.id, onChange: onChange) { $0.device = .laserCube } }
                }
                if output.device == .laserCube {
                    Text("IP ADDRESS", size: 12, color: outputMuted)
                    if isEditingAddress {
                        Text(addressText.isEmpty ? "—" : addressText, size: 18, color: outputText)
                        if addressInvalid { Text("ENTER A VALID IPV4 ADDRESS", size: 11, color: XColorValue(hex: 0xef9185)) }
                        ForEach(["123", "456", "789", ".0"]) { row in
                            HStack(spacing: 8) {
                                ForEach(Array(row).map { String($0) }) { key in
                                    button(key) { guard let draft, draft.value.count < 15 else { return }; draft.value += key; error?.value = false }
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            button("DELETE") { if let draft, !draft.value.isEmpty { draft.value.removeLast(); error?.value = false } }
                            button("CANCEL") { addressPage?.value = false; error?.value = false }
                            button("DONE") {
                                guard let draft, LaserOutput.isValidIPv4(draft.value) else { error?.value = true; return }
                                updateOutput(state, output.id, onChange: onChange) { $0.address = draft.value }
                                addressPage?.value = false; error?.value = false
                            }
                        }
                    } else {
                        button(output.address.isEmpty ? "SET IP ADDRESS  ›" : "\(output.address)  ·  EDIT ›") {
                            draft?.value = output.address; error?.value = false; addressPage?.value = true
                        }
                    }
                }
                }
                if output.device == .laserCube && LaserOutput.isValidIPv4(output.address), let connections {
                    if status == "CONNECTED" {
                        button("DISCONNECT") {
                            setStatus(statuses, output.id, "DISCONNECTING"); invalidate()
                            Task { @XUIActor in
                                await stopTestPatterns()
                                do { try await connections.disconnect(output.id); setStatus(statuses, output.id, "NOT CONNECTED") }
                                catch { setStatus(statuses, output.id, "DISCONNECT FAILED: \(error)") }
                                invalidate()
                            }
                        }
                    } else if status != "CONNECTING" && status != "DISCONNECTING" {
                        button("CONNECT") {
                            setStatus(statuses, output.id, "CONNECTING"); invalidate()
                            Task { @XUIActor in
                                do { try await connections.connect(output, automatic: false); setStatus(statuses, output.id, "CONNECTED") }
                                catch { setStatus(statuses, output.id, "CONNECT FAILED: \(error)") }
                                invalidate()
                            }
                        }
                    }
                }
                Text("OUTPUT SETTINGS", size: 12, color: outputMuted)
                button("SAFETY MASKS   \(output.masks.masks.count)   ›") {
                    Task { await stopTestPatterns() }
                    guard let connections else { masksPage?.value = true; return }
                    Task { @XUIActor in
                        let hasSession = await connections.status(of: output.id).connected
                        setStatus(statuses, output.id, hasSession ? "CONNECTED" : "NOT CONNECTED")
                        masksPage?.value = true
                        invalidate()
                    }
                }
                Text("Masks belong to this output and remain when its device changes.", size: 11, color: outputMuted)
                if status == "CONNECTED", connections != nil {
                    let active = testPattern[output.id], power = testPower
                    Text("TEST PATTERN", size: 12, color: outputMuted)
                    HStack(spacing: 8) {
                        ForEach(LaserTestPatterns.all.map(\.name)) { name in
                            button(active == name ? "● \(name)" : "○ \(name)") { showTestPattern(active == name ? nil : name, on: output, percent: power) }
                        }
                    }
                    HStack(spacing: 8) {
                        Text("BRIGHTNESS", size: 11, color: outputMuted)
                        ForEach(["5", "10", "25", "50"]) { percent in
                            button(power == Int(percent) ? "● \(percent)%" : "○ \(percent)%") {
                                guard let value = Int(percent) else { return }
                                _testPower?.value = value
                                if let active { showTestPattern(active, on: output, percent: value) } else { invalidate() }
                            }
                        }
                    }
                    if let active {
                        Text("SHOWING \(active) AT \(power)%  ·  THE LASER IS ON, NOT PLAYING ITS ZONE", size: 11, color: outputAccent)
                        button("TEST PATTERN OFF") { showTestPattern(nil, on: output, percent: power) }
                    }
                    if let note = testNote[output.id] { Text(note, size: 11, color: XColorValue(hex: 0xef9185)) }
                    Text("The ILDA test pattern goes to the device as it is, without masks. It ends when this screen is left.", size: 11, color: outputMuted)
                }
            } else {
                Text("SELECT OR CREATE AN OUTPUT", size: 15, color: outputMuted)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading).background { Rectangle(fill: outputBackground) }
    }

    /// Shows the test pattern `name` on the output (`nil`: ends it and gives the laser back to its zone).
    private func showTestPattern(_ name: String?, on output: LaserOutput, percent: Int) {
        guard let connections, let shown = _testPattern, let notes = _testNote else { return }
        let invalidate = invalidate
        Task { @XUIActor in
            do {
                if let name {
                    let points = try LaserTestPatterns.points(named: name, intensity: Float(percent) / 100)
                    try await connections.showPattern(points, for: output.id)
                    var next = shown.value; next[output.id] = name; shown.value = next
                } else {
                    try await connections.setPreview(false, for: output.id, masks: .init())
                    var next = shown.value; next[output.id] = nil; shown.value = next
                }
                var next = notes.value; next[output.id] = nil; notes.value = next
            } catch {
                var next = notes.value; next[output.id] = "\(error)"; notes.value = next
            }
            invalidate()
        }
    }

    /// Ends every test pattern this screen is showing.
    private func stopTestPatterns() async {
        guard let connections, let shown = _testPattern else { return }
        let active = Array(shown.value.keys)
        shown.value = [:]
        for id in active { try? await connections.setPreview(false, for: id, masks: .init()) }
    }

    private func button(_ title: String, action: @escaping @Sendable () -> Void) -> some XView {
        Text(title, size: 12, color: outputText).padding(9)
            .background { RoundedRectangle(cornerRadius: 5, fill: XColorValue(hex: 0x384641)) }
            .onTapGesture(id: "laser.output.\(title)", label: title, action)
    }
}

private func updateOutput(_ state: StateStore.Box<LaserOutputCollection>?, _ id: UUID, onChange: @Sendable (LaserOutputCollection) -> Void, _ change: (inout LaserOutput) -> Void) {
    guard let state else { return }
    var next = state.value
    guard let index = next.outputs.firstIndex(where: { $0.id == id }) else { return }
    change(&next.outputs[index]); state.value = next
    onChange(next)
}

private func setStatus(_ state: StateStore.Box<[UUID: String]>?, _ id: UUID, _ status: String) {
    guard let state else { return }; var next = state.value; next[id] = status; state.value = next
}

extension LaserOutputConfigView: _Stateful {}
