// What the file browser costs, by folder size and by layout.
//
//   swift build -c release --product xworkspace-bench && .build/release/xworkspace-bench
//
// Filters: XB_ONLY=<substring of a scenario name>, XB_N=<one folder size>.
// Times are the median of several runs. A frame budget at 60 Hz is 16 667 µs.

import Foundation
import XUI
import XWorkspace
import XWorkspaceUI

nonisolated(unsafe) var checksum = 0

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) }

func median(runs: Int = 7, _ body: () -> Void) -> Double {
    body()
    var samples: [Double] = []
    for _ in 0..<runs { let t0 = now(); body(); samples.append(now() - t0) }
    samples.sort()
    return samples[samples.count / 2]
}

let only = ProcessInfo.processInfo.environment["XB_ONLY"]
let onlyN = Int(ProcessInfo.processInfo.environment["XB_N"] ?? "")

func wanted(_ name: String, _ n: Int) -> Bool {
    if let only, !name.contains(only) { return false }
    if let onlyN, onlyN != n { return false }
    return true
}

func line(_ name: String, n: Int, nanoseconds: Double, per: Int = 1, unit: String = "ms") {
    let value: Double
    switch unit {
    case "µs": value = nanoseconds / 1e3
    case "ns": value = nanoseconds
    default: value = nanoseconds / 1e6
    }
    let perItem = nanoseconds / Double(max(1, per))
    print(String(format: "%-44@ N=%-8d %12.3f %@  %10.1f ns/item", name as NSString, n, value, unit as NSString, perItem))
}

func makeEntries(_ n: Int) -> [WorkspaceEntry] {
    let folder = UUID()
    let extensions = ["png", "mov", "wav", "fs", "ild", "txt", "jpg"]
    return (0..<n).map { i in
        // A mixed bag: numbered takes, camel-case, a few folders.
        let name: String
        switch i % 5 {
        case 0: name = "Take \((i * 7919) % (n + 1)) - clip\(i % 97)"
        case 1: name = "IMG_\(String(format: "%05d", (i * 31) % 100_000))"
        case 2: name = "scene\((i * 13) % 1000)_layer\(i % 9)"
        case 3: name = "Cue Final v\(i % 12)"
        default: name = "asset-\(i)"
        }
        let isDirectory = i % 40 == 0
        return WorkspaceEntry(folderID: folder, path: isDirectory ? name : name + "." + extensions[i % extensions.count],
                              kind: isDirectory ? .directory : .file, size: Int64(i * 1024 % 5_000_000))
    }
}

// MARK: - rendering helpers

final class NullCanvas: XCanvas {
    func fillRect(_ rect: Rect, color: XColorValue) {}
    func fillRoundedRect(_ rect: Rect, cornerRadius: Double, color: XColorValue) {}
    func strokeRoundedRect(_ rect: Rect, cornerRadius: Double, color: XColorValue, lineWidth: Double) {}
    func fillEllipse(in rect: Rect, color: XColorValue) {}
    func fillPath(_ path: Path, in rect: Rect, color: XColorValue) {}
    func strokePath(_ path: Path, in rect: Rect, color: XColorValue, lineWidth: Double) {}
    func drawImage(_ source: ImageSource, in rect: Rect, opacity: Double) {}
    func drawText(_ string: String, in rect: Rect, fontSize: Double, font: TextFont,
                  color: XColorValue, alignment: HorizontalAlignment, outline: TextOutline?) {}
    func measureText(_ string: String, fontSize: Double, font: TextFont) -> Size {
        Size(width: Double(string.count) * fontSize * 0.55, height: fontSize * 1.2)
    }
    func pushClip(_ rect: Rect) {}
    func popClip() {}
    func pushTransform(_ transform: XTransform) {}
    func popTransform() {}
}

final class RenderRequest<V: XView>: @unchecked Sendable {
    let view: V, host: LayoutHost, canvas: any XCanvas, store: StateStore
    init(view: V, host: LayoutHost, canvas: any XCanvas, store: StateStore) {
        self.view = view; self.host = host; self.canvas = canvas; self.store = store
    }
}

func blockingRender<V: XView>(_ view: V, host: LayoutHost, store: StateStore) {
    let request = RenderRequest(view: view, host: host, canvas: NullCanvas(), store: store)
    let done = DispatchSemaphore(value: 0)
    Task { @XUIActor in
        let result = await request.host.render(request.view, into: request.canvas, store: request.store)
        checksum &+= result.tapGestures.count
        done.signal()
    }
    done.wait()
}

func frames(_ name: String, n: Int, count: Int, view: () -> some XView, size: Size) {
    guard wanted(name, n) else { return }
    let view = view()
    let host = LayoutHost(canvas: size)
    let store = StateStore()
    let total = median(runs: 5) { for _ in 0..<count { blockingRender(view, host: host, store: store) } }
    line(name, n: n, nanoseconds: total / Double(count), unit: "µs")
}

// MARK: - 1. ordering and filtering

print("Browser cost — frame budget 16 667 µs at 60 Hz\n")
print("# listing → display order (once per folder load)")
for n in [1_000, 10_000, 100_000] {
    let entries = makeEntries(n)
    if wanted("build items", n) {
        var items: [BrowserItem] = []
        let t = median(runs: 5) { items = entries.map { BrowserItem(entry: $0) } }
        line("build items (name fold, category)", n: n, nanoseconds: t, per: n)
        checksum &+= items.count
    }
    let items = entries.map { BrowserItem(entry: $0) }
    if wanted("sort fast", n) {
        let t = median(runs: 5) { checksum &+= BrowserOrdering.sorted(items).count }
        line("sort — byte-wise natural order", n: n, nanoseconds: t, per: n)
    }
    if wanted("sort reference", n), n <= 100_000 {
        let t = median(runs: 3) { checksum &+= BrowserOrdering.referenceSorted(items).count }
        line("sort — localizedStandardCompare (baseline)", n: n, nanoseconds: t, per: n)
    }
    let sorted = BrowserOrdering.sorted(items)
    if wanted("filter fast", n) {
        let t = median(runs: 7) { checksum &+= BrowserOrdering.visible(in: sorted, filter: .all, query: "clip1").count }
        line("filter — query \"clip1\"", n: n, nanoseconds: t, per: n)
        let u = median(runs: 7) { checksum &+= BrowserOrdering.visible(in: sorted, filter: BrowserFilter(categories: [.image]), query: "").count }
        line("filter — category images", n: n, nanoseconds: u, per: n)
    }
    if wanted("filter reference", n) {
        let t = median(runs: 3) { checksum &+= BrowserOrdering.referenceVisible(in: sorted, query: "clip1").count }
        line("filter — localizedCaseInsensitiveContains (baseline)", n: n, nanoseconds: t, per: n)
    }
}

// MARK: - 2. layout decision

if wanted("layout policy", onlyN ?? 0) || onlyN == nil {
    let policy = BrowserLayoutPolicy()
    let sizes = [Size(width: 240, height: 700), Size(width: 520, height: 480), Size(width: 900, height: 140), Size(width: 1200, height: 800)]
    let reps = 200_000
    let t = median(runs: 5) {
        var shape: BrowserLayout.Shape?
        for i in 0..<reps {
            let layout = policy.layout(for: sizes[i & 3], previous: shape)
            shape = layout.shape
            checksum &+= layout.tracks
        }
    }
    if only == nil || only!.contains("layout policy") { line("layout policy decision", n: 1, nanoseconds: t / Double(reps), unit: "ns") }
}

// MARK: - 3. one frame

print("\n# one rendered frame (layout + paint recording), by folder size")
let sizes: [(String, Size)] = [("tall 360x800", Size(width: 360, height: 800)), ("square 520x480", Size(width: 520, height: 480)),
                               ("strip 900x140", Size(width: 900, height: 140)), ("roomy 1200x800", Size(width: 1200, height: 800))]
for n in [1_000, 10_000, 100_000, 1_000_000] {
    let model = FileBrowserModel(workspace: try! Workspace(access: LocalWorkspaceAccessProvider()))
    model.showItems(makeEntries(n).map { BrowserItem(entry: $0) })
    for (label, size) in sizes {
        frames("frame browser \(label)", n: n, count: 40, view: { FileBrowserView(model: model) }, size: size)
    }
}

// The same cells without virtualization, to show what LazyGrid saves.
print("\n# baseline: every cell built (ScrollView + VStack + ForEach)")
for n in [1_000, 10_000] {
    struct Naive: XView {
        let n: Int
        var body: some XView {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(0..<n) { i in
                        Text("clip \(i)", size: 12, color: .white).frame(width: 300, height: 52)
                            .background { RoundedRectangle(cornerRadius: 8, fill: XColorValue(hex: 0x252b2a)) }
                    }
                }
            }
        }
    }
    frames("frame naive list (no virtualization)", n: n, count: n >= 10_000 ? 3 : 10, view: { Naive(n: n) }, size: Size(width: 360, height: 800))
}

// MARK: - 4. real directories

print("\n# real directory on disk (Workspace.list, then the whole load: list + items + order)")
func blocking(_ body: @escaping @Sendable () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task { await body(); done.signal() }
    done.wait()
}

for n in [1_000, 10_000, 50_000] where only == nil || only!.contains("disk") {
    if let onlyN, onlyN != n { continue }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("xworkspace-bench-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let extensions = ["png", "mov", "wav", "fs", "ild"]
    for i in 0..<n {
        FileManager.default.createFile(atPath: base.appendingPathComponent("clip \(i * 7 % n).\(extensions[i % 5])").path, contents: nil)
    }
    let workspace = try! Workspace(access: LocalWorkspaceAccessProvider())
    nonisolated(unsafe) var folderID = UUID()
    blocking { folderID = try! await workspace.register(directory: base).id }
    let id = folderID

    let listing = median(runs: 5) {
        blocking { checksum &+= (try! await workspace.list(folderID: id, sorted: false)).count }
    }
    line("Workspace.list (unsorted)", n: n, nanoseconds: listing, per: n)
    let sortedListing = median(runs: 3) {
        blocking { checksum &+= (try! await workspace.list(folderID: id, sorted: true)).count }
    }
    line("Workspace.list (localized sort, old default)", n: n, nanoseconds: sortedListing, per: n)

    let model = FileBrowserModel(workspace: workspace)
    model.open(.folder(id: id, path: ""))
    let load = median(runs: 5) { blocking { await model.reload() } }
    line("browser load: list + items + order", n: n, nanoseconds: load, per: n)
    checksum &+= model.snapshot().items.count

    let stamp = median(runs: 9) { blocking { checksum &+= (try! await workspace.directoryStamp(folderID: id)) == nil ? 0 : 1 } }
    line("change check (directory stamp)", n: n, nanoseconds: stamp, unit: "µs")
}
print("\nchecksum \(checksum)")
