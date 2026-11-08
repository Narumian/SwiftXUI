import Foundation
import XUI

private let pageBackground = XColorValue(hex: 0x171a1d)
private let panel = XColorValue(hex: 0x252a2e)
private let foreground = XColorValue(hex: 0xe8eeeb)
private let secondary = XColorValue(hex: 0xa9b5b0)
private let accent = XColorValue(hex: 0x80c9b2)

/// The scanner settings, shared by every output: every `LaserScannerParameter` as a slider,
/// and the screen-edge mode. Changes are saved as they are made.
public struct LaserScannerSettingsView: XView, Sendable {
    private var _profile: StateStore.Box<LaserScannerSettings>?
    private var profile: LaserScannerSettings { _profile?.value ?? initialProfile }
    public mutating func _installState(id: StateIdentity, store: StateStore) {
        _profile = store._xstateBox(id: id, name: "profile", default: { initialProfile })
    }

    let initialProfile: LaserScannerSettings
    let onChange: @Sendable (LaserScannerSettings) -> Void
    let onBack: @Sendable () -> Void

    public init(initial: LaserScannerSettings = .init(),
                onChange: @escaping @Sendable (LaserScannerSettings) -> Void = { _ in },
                onBack: @escaping @Sendable () -> Void = {}) {
        self.initialProfile = initial; self.onChange = onChange; self.onBack = onBack
    }

    public var body: some XView {
        let box = _profile
        let current = profile
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("‹ OUTPUTS", size: 14, color: accent).padding(6).onTapGesture(id: "scanner.back", label: "OUTPUTS", onBack)
                Text("SCANNER SETTINGS", size: 18, color: foreground)
                Spacer()
                Text("AUTO SAVE", size: 12, color: secondary)
            }.padding(12).background { Rectangle(fill: panel) }
            ScrollView(id: "laser.scanner.settings") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("ALL OUTPUTS", size: 12, color: secondary)
                    Text("OFF-SCREEN", size: 12, color: secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(LaserScannerSettingsView.screenModes) { mode in
                            Text("\(current.screen == mode.mode ? "●" : "○")  \(mode.title)", size: 13, color: current.screen == mode.mode ? accent : foreground)
                                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                .background { RoundedRectangle(cornerRadius: 4, fill: current.screen == mode.mode ? XColorValue(hex: 0x344941) : XColorValue(hex: 0x3a4240)) }
                                .onTapGesture(id: "scanner.screen.\(mode.mode.rawValue)", label: mode.title) { edit(box) { $0.screen = mode.mode } }
                        }
                    }
                    ForEach(LaserScannerParameter.allCases) { parameter in
                        row(parameter, profile: current, box: box)
                    }
                    Text("RESET ALL", size: 12, color: foreground).padding(9)
                        .background { RoundedRectangle(cornerRadius: 4, fill: XColorValue(hex: 0x3a4240)) }
                        .onTapGesture(id: "scanner.reset.all", label: "RESET ALL") { edit(box) { $0 = LaserScannerSettings() } }
                }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background { Rectangle(fill: pageBackground) }
    }

    private func row(_ parameter: LaserScannerParameter, profile: LaserScannerSettings, box: StateStore.Box<LaserScannerSettings>?) -> some XView {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(parameter.label, size: 12, color: foreground)
                Spacer()
                Text(parameter.display(profile), size: 12, color: accent)
                Text("RESET", size: 10, color: secondary).padding(6)
                    .onTapGesture(id: "scanner.reset.\(parameter.rawValue)", label: "RESET \(parameter.label)") {
                        edit(box) { parameter.set(parameter.defaultValue, in: &$0) }
                    }
            }
            GeometryReader { geometry in
                let value = parameter.normalized(in: profile)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 2, fill: secondary).frame(height: 4).position(x: geometry.width / 2, y: 15)
                    Circle(fill: accent).frame(width: 20, height: 20).position(x: 10 + max(0, geometry.width - 20) * value, y: 15)
                }.gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let n = min(1, max(0, (drag.location.x - geometry.frame.x - 10) / max(1, geometry.width - 20)))
                    edit(box) { parameter.setNormalized(n, in: &$0) }
                })
            }.frame(height: 30)
        }
    }

    private func edit(_ box: StateStore.Box<LaserScannerSettings>?, _ change: (inout LaserScannerSettings) -> Void) {
        guard let box else { return }
        var next = box.value
        change(&next)
        guard next != box.value else { return }
        box.value = next
        onChange(next)
    }

    fileprivate struct ScreenModeItem: Sendable, Identifiable { let mode: LaserScreenMode; let title: String; var id: String { mode.rawValue } }
    private static let screenModes: [ScreenModeItem] = [
        ScreenModeItem(mode: .clamp, title: "CLAMP  ·  squash onto the edge"),
        ScreenModeItem(mode: .cut, title: "CUT  ·  cut at the edge, with padding"),
        ScreenModeItem(mode: .blanking, title: "BLANKING  ·  dark outside, rhythm kept"),
        ScreenModeItem(mode: .blankingWithPadding, title: "BLANKING + PADDING"),
    ]
}

extension LaserScannerSettingsView: _Stateful {}
