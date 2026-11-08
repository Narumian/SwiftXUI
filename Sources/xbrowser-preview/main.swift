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
print("wrote PNGs to \(outDirectory.path)")
