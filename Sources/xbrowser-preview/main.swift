import Foundation
import XPreview
import XRender
import XUI
import XUIHost
import XWorkspace
import XWorkspaceUI

// xbrowser-preview [--out DIR] [--files N] [--font TTF] [--shape NAME] [--scenario NAME] [--frames N]
//
// Renders the file browser, as the app does, in several box shapes and states, writes a PNG
// for each, and prints what each costs per frame.

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
let outDirectory = URL(fileURLWithPath: option("--out") ?? FileManager.default.currentDirectoryPath)
let fileCount = Int(option("--files") ?? "") ?? 3000
let onlyShape = option("--shape")
let onlyScenario = option("--scenario")
let measuredFrames = Int(option("--frames") ?? "") ?? 120
try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)

// Fonts: explicit, or the Trident UI font if the repositories sit side by side.
var fonts: [FontRole: Data] = [:]
let fontPath = option("--font") ?? "../Trident/TridentKit/Sources/TridentKit/Resources/Fonts/ZenMaruGothic-Medium.ttf"
if let data = try? Data(contentsOf: URL(fileURLWithPath: fontPath)) {
    fonts = [.ui: data, .display: data, .numeric: data, .impact: data]
} else {
    print("note: no font at \(fontPath); using the built-in vector font")
}

// A folder with a realistic mix of names, extensions and sub folders.
let base = FileManager.default.temporaryDirectory.appendingPathComponent("xbrowser-preview-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: base) }
let media = base.appendingPathComponent("Media")
try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
for folder in ["Shaders", "Laser Shows", "Footage", "Logos"] {
    try FileManager.default.createDirectory(at: media.appendingPathComponent(folder), withIntermediateDirectories: true)
}
for folder in ["Shaders/Old", "Shaders/Tests", "Footage/2025", "Laser Shows/Club"] {
    try FileManager.default.createDirectory(at: media.appendingPathComponent(folder), withIntermediateDirectories: true)
}
for file in ["Shaders/plasma.fs", "Shaders/tunnel.isf", "Shaders/Old/spiral v1.fs", "Shaders/Old/burst v1.fs", "Footage/loop.mov",
             "Footage/2025/intro.mp4", "Footage/2025/outro.mp4", "Laser Shows/Club/set 1.ild", "Laser Shows/Club/set 2.ild", "Logos/mark.svg"] {
    try Data([1]).write(to: media.appendingPathComponent(file))
}
let extensions = ["png", "jpg", "mov", "mp4", "wav", "isf", "fs", "ild", "txt", "json", "svg", "trident"]
let stems = ["plasma", "tunnel", "alpha mask", "logo", "wave", "burst", "spiral", "fractal", "grid", "title card", "loop"]
for i in 0..<fileCount {
    let name = "\(stems[i % stems.count]) \(i / stems.count + 1).\(extensions[i % extensions.count])"
    try Data([1]).write(to: media.appendingPathComponent(name))
}
let workspace = try Workspace(access: LocalWorkspaceAccessProvider())
let folderID = try await workspace.register(directory: media, name: "Media").id

struct Scenario {
    var name: String
    var script: @XUIActor (PreviewDriver, FileBrowserModel) async -> Void
}
let scenarios: [Scenario] = [
    Scenario(name: "folder") { driver, _ in await driver.advance(frames: 5) },
    Scenario(name: "scrolled") { driver, _ in
        let f = await driver.advance(frames: 3)
        let w = Double(driver.host.size.width), h = Double(driver.host.size.height)
        _ = f
        driver.drag(from: Point(x: w * 0.6, y: h * 0.8), to: Point(x: w * 0.6, y: h * 0.2), steps: 8)
        await driver.advance(frames: 5)
    },
    Scenario(name: "search") { driver, model in
        driver.host.textFocus.keyboardPolicy = .always
        await driver.advance(frames: 3)
        _ = await driver.tap("browser.search.open")
        await driver.advance(frames: 12)
        driver.type("plasma")
        await driver.advance(frames: 12)
    },
]

print(String(format: "%-16@ %-9@ %@", "shape" as NSString, "scenario" as NSString, "cost per frame" as NSString))
for shape in PreviewShape.standard where onlyShape == nil || shape.name == onlyShape {
    for scenario in scenarios where onlyScenario == nil || scenario.name == onlyScenario {
        let model = FileBrowserModel(workspace: workspace)
        model.open(.folder(id: folderID, path: ""))
        await model.reload()
        let result = try await XPreview(fonts: fonts, measuredFrames: measuredFrames).render(shape, script: { driver in
            await scenario.script(driver, model)
        }) {
            TextInputArea { FileBrowserView(model: model, onAddFolder: {}) }
        }
        let file = outDirectory.appendingPathComponent("browser-\(shape.name)-\(scenario.name).png")
        try result.png.write(to: file)
        print(String(format: "%-16@ %-9@ %@", shape.name as NSString, scenario.name as NSString, result.stats.summary as NSString))
    }
}

// The on-screen keyboard on its own (a bare field, no browser behind it), so its cost is not
// mixed up with the page's. "opening" times the slide-in frames, which no settled run sees.
if onlyScenario == nil || onlyScenario == "keyboard" {
    struct KeyboardCase { var name: String; var script: @XUIActor (PreviewDriver, PreviewShape) async -> Void }
    nonisolated(unsafe) var openingMs: [Double] = []
    let cases: [KeyboardCase] = [
        KeyboardCase(name: "field-only") { driver, _ in driver.host.textFocus.keyboardPolicy = .never; await driver.advance(frames: 3) },
        KeyboardCase(name: "kb-idle") { driver, _ in
            driver.host.textFocus.keyboardPolicy = .always
            await driver.advance(frames: 3)
            driver.host.textFocus.focus("kb.field")
            await driver.advance(frames: 20)
        },
        KeyboardCase(name: "kb-held") { driver, shape in
            driver.host.textFocus.keyboardPolicy = .always
            await driver.advance(frames: 3)
            driver.host.textFocus.focus("kb.field")
            await driver.advance(frames: 20)
            let m = KeyboardMetrics.compute(container: Size(width: Double(shape.width), height: Double(shape.height)), rowCount: 4)
            driver.press(at: Point(x: m.rect.midX, y: m.rect.y + m.padding + m.keyHeight * 1.5 + m.gap), id: 7)
            await driver.advance(frames: 5)
        },
        KeyboardCase(name: "kb-opening") { driver, _ in
            driver.host.textFocus.keyboardPolicy = .always
            await driver.advance(frames: 3)
            driver.host.textFocus.focus("kb.field")
            openingMs = []
            for _ in 0..<20 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                await driver.advance()
                openingMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
        },
    ]
    print("")
    print(String(format: "%-16@ %-11@ %@", "shape" as NSString, "keyboard" as NSString, "cost per frame" as NSString))
    for shape in PreviewShape.standard where onlyShape == nil || shape.name == onlyShape {
        for kase in cases {
            let result = try await XPreview(fonts: fonts, measuredFrames: measuredFrames).render(shape, script: { driver in
                await kase.script(driver, shape)
            }) {
                TextInputArea { KeyboardBench() }
            }
            try result.png.write(to: outDirectory.appendingPathComponent("keyboard-\(shape.name)-\(kase.name).png"))
            var line = result.stats.summary
            if kase.name == "kb-opening", !openingMs.isEmpty {
                line += String(format: "   slide-in 20 frames: mean %.2f max %.2f ms", openingMs.reduce(0, +) / Double(openingMs.count), openingMs.max() ?? 0)
            }
            print(String(format: "%-16@ %-11@ %@", shape.name as NSString, kase.name as NSString, line as NSString))
        }
    }
}

@Stateful
struct KeyboardBench: XView {
    @XState private var text: String = ""
    var body: some XView {
        let box = _text
        VStack(spacing: 12) {
            Text("KEYBOARD", size: 14, color: .white)
            TextField("type here", text: Binding(get: { box?.value ?? "" }, set: { box?.value = $0 }), id: "kb.field")
        }.padding(16).frame(width: .fraction(1), height: .fraction(1), alignment: .topLeading)
    }
}


// The outline view: folders open in place.
if onlyScenario == nil || onlyScenario == "tree" {
    print("")
    print(String(format: "%-16@ %-11@ %@", "shape" as NSString, "tree" as NSString, "cost per frame" as NSString))
    for shape in PreviewShape.standard where onlyShape == nil || shape.name == onlyShape {
        let model = FileTreeModel(workspace: workspace, folderID: folderID)
        await model.reload()
        model.onDrop = { _, _ in true }
        model.contextMenu = { entry in [ContextMenuItem("Rename") {}, ContextMenuItem("Duplicate") {}, ContextMenuItem("Delete", role: .destructive) {}] }
        let result = try await XPreview(fonts: fonts, measuredFrames: measuredFrames).render(shape, script: { driver in
            await driver.advance(frames: 3)
            // Open folders the way a finger would: tap the row by its name.
            for name in ["Shaders", "Old", "Footage", "Laser Shows"] {
                let frame = await driver.advance()
                if let row = frame.layout.tapGestures.first(where: { $0.id == "tree.row" && $0.label == name }) {
                    driver.tap(at: Point(x: row.rect.midX, y: row.rect.midY))
                    for _ in 0..<100 where model.snapshot().rows.contains(where: { $0.isLoading }) { try? await Task.sleep(nanoseconds: 10_000_000) }
                }
            }
            await driver.advance(frames: 3)
        }) {
            DragDropArea { FileTreeView(model: model) }
        }
        try result.png.write(to: outDirectory.appendingPathComponent("tree-\(shape.name).png"))
        print(String(format: "%-16@ %-11@ %@", shape.name as NSString, "open" as NSString, result.stats.summary as NSString))
    }

    // Drag a file row over a folder row (held, mid-flight), and lift one and release it in place (menu).
    for (name, scenario) in [("tree-drag", "drag"), ("tree-menu", "menu")] {
        for shape in [PreviewShape.phonePortrait, .tablet] where onlyShape == nil || shape.name == onlyShape {
            let model = FileTreeModel(workspace: workspace, folderID: folderID)
            await model.reload()
            model.onDrop = { _, _ in true }
            model.contextMenu = { _ in [ContextMenuItem("Rename") {}, ContextMenuItem("Duplicate") {}, ContextMenuItem("Delete", role: .destructive) {}] }
            let result = try await XPreview(fonts: fonts, measuredFrames: measuredFrames).render(shape, script: { driver in
                driver.host.dragDrop.slop = 24
                await driver.advance(frames: 3)
                @XUIActor func row(_ label: String) -> Rect? { driver.frame?.layout.tapGestures.first { $0.id == "tree.row" && $0.label == label }?.rect }
                await driver.advance()
                guard let file = row("alpha mask 1.mov"), let folder = row("Footage") else { return }
                driver.press(at: Point(x: file.midX, y: file.midY))
                await driver.advance(frames: 20)
                if scenario == "drag" {
                    driver.move(to: Point(x: folder.midX, y: folder.midY))
                    await driver.advance(frames: 8)
                } else {
                    driver.release(at: Point(x: file.midX, y: file.midY))
                    await driver.advance(frames: 14)
                }
            }) {
                DragDropArea { FileTreeView(model: model) }
            }
            try result.png.write(to: outDirectory.appendingPathComponent("\(name)-\(shape.name).png"))
            print(String(format: "%-16@ %-11@ %@", shape.name as NSString, scenario as NSString, result.stats.summary as NSString))
        }
    }

    // The cost of opening one big folder: list, order, flatten.
    let model = FileTreeModel(workspace: workspace, folderID: folderID)
    await model.reload()
    let start = DispatchTime.now().uptimeNanoseconds
    model.expand(.init(folderID: folderID, path: "Shaders"))
    model.collapse(.init(folderID: folderID, path: "Shaders"))
    let toggle = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    print("rows with Media open: \(model.snapshot().rows.count) (\(fileCount) files + folders); expand+collapse of a small folder: \(String(format: "%.3f", toggle)) ms")
}

print("wrote PNGs to \(outDirectory.path)")
