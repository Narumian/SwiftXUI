import Foundation
import XUI

private let maskBackground = XColorValue(hex: 0x171a1d)
private let panel = XColorValue(hex: 0x252a2e)
private let foreground = XColorValue(hex: 0xe8eeeb)
private let secondary = XColorValue(hex: 0xa9b5b0)
private let accent = XColorValue(hex: 0x80c9b2)
private let maskColor = XColorValue(0.86, 0.42, 0.36, 0.45)

public struct LaserMaskEditor: XView, Sendable {
    private var _settings: StateStore.Box<LaserMaskSettings>?
    private var _selected: StateStore.Box<Int>?
    private var _saved: StateStore.Box<Bool>?
    private var _previewStatus: StateStore.Box<String>?
    private var settings: LaserMaskSettings { _settings?.value ?? initialSettings }
    private var selected: Int { _selected?.value ?? 0 }
    private var saved: Bool { _saved?.value ?? true }
    private var previewStatus: String { _previewStatus?.value ?? "OFF" }
    public mutating func _installState(id: StateIdentity, store: StateStore) {
        _settings = store._xstateBox(id: id, name: "settings", default: { initialSettings })
        _selected = store._xstateBox(id: id, name: "selected", default: { 0 })
        _saved = store._xstateBox(id: id, name: "saved", default: { true })
        _previewStatus = store._xstateBox(id: id, name: "previewStatus", default: { "OFF" })
    }

    let initialSettings: LaserMaskSettings
    let outputName: String
    let hasConnection: Bool
    let connections: LaserOutputConnections?
    let outputID: UUID?
    let invalidate: @Sendable () -> Void
    let onSave: @Sendable (LaserMaskSettings) -> Void
    let onBack: @Sendable () -> Void

    public init(initialSettings: LaserMaskSettings = .init(), outputName: String = "LASER 01", hasConnection: Bool = false,
         connections: LaserOutputConnections? = nil, outputID: UUID? = nil, invalidate: @escaping @Sendable () -> Void = {},
         onSave: @escaping @Sendable (LaserMaskSettings) -> Void = { _ in },
         onBack: @escaping @Sendable () -> Void = {}) {
        self.initialSettings = initialSettings; self.outputName = outputName; self.hasConnection = hasConnection
        self.connections = connections; self.outputID = outputID; self.invalidate = invalidate
        self.onSave = onSave; self.onBack = onBack
    }

    public var body: some XView {
        let state = _settings
        let selection = _selected
        let savedBox = _saved
        let previewBox = _previewStatus
        let status = previewStatus
        let masks = settings.masks
        let index = min(max(0, selected), max(0, masks.count - 1))
        let current = masks.indices.contains(index) ? masks[index] : nil
        GeometryReader { geometry in
            let wide = geometry.width >= 650 && geometry.width > geometry.height
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("‹ OUTPUT", size: 14, color: accent).padding(6).onTapGesture {
                        guard let connections, let outputID, status != "OFF" else { onBack(); return }
                        previewBox?.value = "STOPPING"
                        Task { @XUIActor in
                            do {
                                try await connections.setPreview(false, for: outputID, masks: .init())
                                previewBox?.value = "OFF"
                                onBack()
                            } catch { previewBox?.value = "ERROR: \(error.localizedDescription)" }
                            invalidate()
                        }
                    }
                    Text("SAFETY MASK", size: 18, color: foreground)
                    Spacer()
                    Text("AUTO SAVE", size: 12, color: secondary)
                }.padding(12).background { Rectangle(fill: panel) }
                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView(id: "laser.mask.list") {
                            list(masks, index: index, state: state, selection: selection, saved: savedBox)
                        }.frame(width: .pt(175))
                        canvas(current, index: index, state: state, saved: savedBox).frame(width: .pt(max(100, geometry.width - 415)))
                        ScrollView(id: "laser.mask.controls") {
                            controls(current, index: index, state: state, selection: selection, saved: savedBox, preview: status, previewBox: previewBox)
                        }.frame(width: .pt(240))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(id: "laser.mask.editor") {
                        VStack(spacing: 10) {
                            list(masks, index: index, state: state, selection: selection, saved: savedBox)
                            canvas(current, index: index, state: state, saved: savedBox).frame(height: .pt(min(max(180, geometry.width - 24), 420)))
                            controls(current, index: index, state: state, selection: selection, saved: savedBox, preview: status, previewBox: previewBox)
                        }.padding(10)
                    }
                }
            }.background { Rectangle(fill: maskBackground) }
        }
    }

    private func list(_ masks: [LaserMask], index: Int, state: StateStore.Box<LaserMaskSettings>?, selection: StateStore.Box<Int>?, saved: StateStore.Box<Bool>?) -> some XView {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(outputName.uppercased())  /  MASKS", size: 12, color: secondary)
            ForEach(Array(masks.enumerated()).map { MaskListItem(index: $0.offset, shape: $0.element.shape, enabled: $0.element.enabled) }) { item in
                Text("\(item.shape == .polygon ? "POLYGON" : "ELLIPSE") \(item.index + 1)  \(item.enabled ? "●" : "○")", size: 13, color: item.index == index ? accent : foreground)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background { RoundedRectangle(cornerRadius: 4, fill: item.index == index ? XColorValue(hex: 0x344941) : panel) }
                    .onTapGesture { selection?.value = item.index }
            }
            VStack(alignment: .leading, spacing: 8) {
                button("+ POLYGON") { guard let state else { return }; var s = state.value; s.masks.append(.make(.polygon)); state.value = s; selection?.value = s.masks.count - 1; saved?.value = false; onSave(state.value) }
                button("+ ELLIPSE") { guard let state else { return }; var s = state.value; s.masks.append(.make(.ellipse)); state.value = s; selection?.value = s.masks.count - 1; saved?.value = false; onSave(state.value) }
            }
        }.padding(10).background { Rectangle(fill: panel) }
    }

    private func controls(_ mask: LaserMask?, index: Int, state: StateStore.Box<LaserMaskSettings>?, selection: StateStore.Box<Int>?, saved: StateStore.Box<Bool>?, preview: String, previewBox: StateStore.Box<String>?) -> some XView {
        VStack(alignment: .leading, spacing: 12) {
            Text("MASK SETTINGS", size: 14, color: foreground)
            if let mask {
                Text(mask.shape == .polygon ? "POLYGON" : "ELLIPSE", size: 12, color: accent)
                if mask.shape == .polygon {
                    HStack(spacing: 8) {
                        button("+ VERTEX") { mutate(state, index, saved, onSave) { mask in
                            guard mask.points.count >= 2 else { return }
                            let a = mask.points[0], b = mask.points[1]
                            mask.points.insert(MaskPoint((a.x + b.x) / 2, (a.y + b.y) / 2), at: 1)
                        } }
                        button("− VERTEX") { mutate(state, index, saved, onSave) { if $0.points.count > 3 { $0.points.removeLast() } } }
                    }
                }
                button(mask.enabled ? "ENABLED  ON" : "ENABLED  OFF") { mutate(state, index, saved, onSave) { $0.enabled.toggle() } }
                slider("SOFT EDGE", value: mask.softEdge) { value in mutate(state, index, saved, onSave) { $0.softEdge = value } }
                slider("DIMMER", value: mask.dimmer) { value in mutate(state, index, saved, onSave) { $0.dimmer = value } }
                Text("0% BLACKOUT   /   100% FULL", size: 11, color: secondary)
                Text(hasConnection ? "DEVICE SESSION OPEN" : "NO DEVICE CONNECTED", size: 11, color: secondary)
                if hasConnection, let connections, let outputID {
                    previewButton("MASK PREVIEW: \(preview)") {
                        guard let previewBox, let state, preview != "STARTING", preview != "STOPPING" else { return }
                        let enable = preview != "ON"
                        previewBox.value = enable ? "STARTING" : "STOPPING"
                        invalidate()
                        Task { @XUIActor in
                            do {
                                try await connections.setPreview(enable, for: outputID, masks: state.value)
                                previewBox.value = enable ? "ON" : "OFF"
                                invalidate()
                                if enable {
                                    while previewBox.value == "ON" {
                                        try? await Task.sleep(nanoseconds: 250_000_000)
                                        if let failure = await connections.streamFailure(outputID) {
                                            previewBox.value = "ERROR: \(failure)"
                                            invalidate()
                                            break
                                        }
                                    }
                                }
                            } catch { previewBox.value = "ERROR: \(error.localizedDescription)"; invalidate() }
                        }
                    }
                } else {
                    Text("CONNECT AN OUTPUT TO PREVIEW", size: 11, color: secondary)
                }
                HStack(spacing: 8) {
                    button("DUPLICATE") { guard let state, state.value.masks.indices.contains(index) else { return }; var s = state.value; var copy = s.masks[index]; copy.id = UUID(); s.masks.append(copy); state.value = s; selection?.value = s.masks.count - 1; saved?.value = false; onSave(state.value) }
                    button("DELETE") { guard let state, state.value.masks.indices.contains(index) else { return }; var s = state.value; s.masks.remove(at: index); state.value = s; selection?.value = max(0, index - 1); saved?.value = false; onSave(state.value) }
                }
            } else {
                Text("ADD A POLYGON OR ELLIPSE", size: 12, color: secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading).background { Rectangle(fill: panel) }
    }

    private func canvas(_ mask: LaserMask?, index: Int, state: StateStore.Box<LaserMaskSettings>?, saved: StateStore.Box<Bool>?) -> some XView {
        GeometryReader { geometry in
            let side = max(1, min(geometry.width, geometry.height))
            let left = (geometry.width - side) / 2
            let top = (geometry.height - side) / 2
            ZStack(alignment: .topLeading) {
                DrawLayer { rect, context in
                    let area = Rect(x: rect.x + left, y: rect.y + top, width: side, height: side)
                    context.canvas.fillRect(area, color: XColorValue(hex: 0x101716))
                    for i in 0...10 {
                        let x = area.x + side * Double(i) / 10, y = area.y + side * Double(i) / 10
                        context.canvas.fillRect(Rect(x: x, y: area.y, width: 1, height: side), color: XColorValue(hex: 0x34403d))
                        context.canvas.fillRect(Rect(x: area.x, y: y, width: side, height: 1), color: XColorValue(hex: 0x34403d))
                    }
                    if let mask, mask.points.count >= 2 {
                        let minX = mask.points.map(\.x).min()!, maxX = mask.points.map(\.x).max()!
                        let minY = mask.points.map(\.y).min()!, maxY = mask.points.map(\.y).max()!
                        let bounds = Rect(x: area.x + minX * side, y: area.y + minY * side, width: (maxX - minX) * side, height: (maxY - minY) * side)
                        if mask.shape == .ellipse { context.canvas.fillEllipse(in: bounds, color: maskColor) }
                        else { context.canvas.fillPath(Path(points: mask.points.map { Point(x: $0.x, y: $0.y) }), in: bounds, color: maskColor) }
                    }
                }
                if let mask {
                    ForEach(Array(mask.points.enumerated()).map { MaskHandle(index: $0.offset, point: $0.element) }) { handle in
                        Circle(fill: accent).frame(width: 24, height: 24)
                            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                                let x = min(1, max(0, (drag.location.x - geometry.frame.x - left) / side))
                                let y = min(1, max(0, (drag.location.y - geometry.frame.y - top) / side))
                                mutate(state, index, saved, onSave) { if $0.points.indices.contains(handle.index) { $0.points[handle.index] = MaskPoint(x, y) } }
                            })
                            .position(x: left + handle.point.x * side, y: top + handle.point.y * side)
                    }
                }
            }
        }.background { Rectangle(fill: maskBackground) }
    }

    private func slider(_ title: String, value: Double, change: @escaping @Sendable (Double) -> Void) -> some XView {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title, size: 12, color: foreground); Spacer(); Text("\(Int(value * 100))%", size: 12, color: accent) }
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 2, fill: secondary).frame(height: 4).position(x: geometry.width / 2, y: 15)
                    Circle(fill: accent).frame(width: 20, height: 20).position(x: 10 + max(0, geometry.width - 20) * value, y: 15)
                }.gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    change(min(1, max(0, (drag.location.x - geometry.frame.x - 10) / max(1, geometry.width - 20))))
                })
            }.frame(height: 30)
        }
    }

    private func button(_ title: String, action: @escaping @Sendable () -> Void) -> some XView {
        Text(title, size: 11, color: foreground).padding(8).background { RoundedRectangle(cornerRadius: 4, fill: XColorValue(hex: 0x3a4240)) }.onTapGesture(action)
    }

    private func previewButton(_ title: String, action: @escaping @Sendable () -> Void) -> some XView {
        Text(title, size: 11, color: foreground).padding(8)
            .background { RoundedRectangle(cornerRadius: 4, fill: XColorValue(hex: 0x3a4240)) }
            .onTapGesture(id: "laser.mask.preview", label: title, action)
    }
}

private struct MaskHandle: Sendable { let index: Int; let point: MaskPoint }
private struct MaskListItem: Sendable { let index: Int; let shape: LaserMask.Shape; let enabled: Bool }
private func mutate(_ state: StateStore.Box<LaserMaskSettings>?, _ index: Int, _ saved: StateStore.Box<Bool>?, _ onSave: @Sendable (LaserMaskSettings) -> Void, _ change: (inout LaserMask) -> Void) {
    guard let state, state.value.masks.indices.contains(index) else { return }
    var settings = state.value
    change(&settings.masks[index])
    state.value = settings
    saved?.value = false
    onSave(settings)
}

extension LaserMaskEditor: _Stateful {}
