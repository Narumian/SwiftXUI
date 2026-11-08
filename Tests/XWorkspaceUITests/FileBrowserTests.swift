import Foundation
import Testing
import XUI
import XWorkspace
@testable import XWorkspaceUI

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) { lock.withLock { paths.append(path) } }
    var all: [String] { lock.withLock { paths } }
}

private struct Fixture {
    let base: URL
    let workspace: Workspace
    let folderID: UUID

    init(files: [String], folders: [String] = []) async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for folder in folders { try FileManager.default.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true) }
        for file in files { try Data([1, 2, 3]).write(to: base.appendingPathComponent(file)) }
        workspace = try Workspace(access: LocalWorkspaceAccessProvider())
        folderID = try await workspace.register(directory: base, name: "Media").id
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

@Test
func browserListsFoldersFirstAndNavigates() async throws {
    let fixture = try await Fixture(files: ["b10.png", "b2.png", "notes.txt"], folders: ["sub"])
    defer { fixture.cleanup() }
    let model = FileBrowserModel(workspace: fixture.workspace)
    model.open(.folder(id: fixture.folderID, path: ""))
    await model.reload()

    var snapshot = model.snapshot()
    #expect(snapshot.items.map(\.name) == ["sub", "b2.png", "b10.png", "notes.txt"])
    #expect(snapshot.visible.count == 4)
    #expect(snapshot.items[1].entry.size == 3)
    #expect(snapshot.title == "Media")

    model.activate(visibleIndex: 0)
    await model.reload()
    snapshot = model.snapshot()
    #expect(snapshot.location == .folder(id: fixture.folderID, path: "sub"))
    #expect(snapshot.canGoUp)

    model.goUp()
    await model.reload()
    #expect(model.snapshot().location == .folder(id: fixture.folderID, path: ""))
    model.goUp()
    await model.reload()
    #expect(model.snapshot().location == .roots)
    #expect(model.snapshot().items.map(\.name) == ["Media"])
}

@Test
func activatingAFilePicksIt() async throws {
    let fixture = try await Fixture(files: ["a.png"])
    defer { fixture.cleanup() }
    let picked = Recorder()
    let model = FileBrowserModel(workspace: fixture.workspace)
    model.onPick = { picked.add($0.path) }
    model.open(.folder(id: fixture.folderID, path: ""))
    await model.reload()
    model.activate(visibleIndex: 0)
    #expect(picked.all == ["a.png"])
    #expect(model.snapshot().selectedPath == "a.png")
}

@Test
func queryAndFilterNarrowTheVisibleItems() async throws {
    let fixture = try await Fixture(files: ["cat.png", "dog.png", "cat.mov"], folders: ["pets"])
    defer { fixture.cleanup() }
    let model = FileBrowserModel(workspace: fixture.workspace)
    model.open(.folder(id: fixture.folderID, path: ""))
    await model.reload()
    model.setQuery("cat")
    #expect(model.snapshot().visible.count == 2)
    model.setFilter(BrowserFilter(categories: [.image]))
    #expect(model.snapshot().visible.map { model.snapshot().items[Int($0)].name } == ["cat.png"])
    model.setQuery("")
    #expect(model.snapshot().visible.count == 3) // pets, cat.png, dog.png
}

@Test
func watchingNoticesNewFiles() async throws {
    let fixture = try await Fixture(files: ["a.png"])
    defer { fixture.cleanup() }
    let model = FileBrowserModel(workspace: fixture.workspace)
    model.open(.folder(id: fixture.folderID, path: ""))
    await model.reload()
    try await Task.sleep(nanoseconds: 30_000_000)
    try Data([1]).write(to: fixture.base.appendingPathComponent("b.png"))
    await model.refreshIfChanged()
    #expect(model.snapshot().items.count == 2)
}

@Test
func missingFolderShowsAnError() async throws {
    let fixture = try await Fixture(files: [])
    defer { fixture.cleanup() }
    let model = FileBrowserModel(workspace: fixture.workspace)
    model.open(.folder(id: fixture.folderID, path: "nope"))
    await model.reload()
    #expect(model.snapshot().error != nil)
    #expect(model.snapshot().items.isEmpty)
}

@XUIActor
private func render(_ model: FileBrowserModel, size: Size) async -> (RecordingSurface, RenderResult) {
    let surface = RecordingSurface()
    let result = await LayoutHost(canvas: size).render(FileBrowserView(model: model), into: surface, store: StateStore())
    return (surface, result)
}

private func names(_ result: RenderResult) -> [String] {
    result.tapGestures.filter { $0.id == "browser.item" }.compactMap(\.label)
}

@Test @XUIActor
func theSameFolderRendersInEveryShape() async throws {
    let files = (0..<600).map { "clip\($0).mov" }
    let fixture = try await Fixture(files: files)
    defer { fixture.cleanup() }
    let model = FileBrowserModel(workspace: fixture.workspace)
    model.open(.folder(id: fixture.folderID, path: ""))
    await model.reload()

    for size in [Size(width: 240, height: 700), Size(width: 520, height: 480), Size(width: 900, height: 140), Size(width: 1200, height: 800)] {
        let (_, result) = await render(model, size: size)
        let shown = names(result)
        #expect(!shown.isEmpty, "nothing drawn at \(size)")
        #expect(shown.count < 600, "not virtualized at \(size)")
        #expect(shown.first == "clip0.mov")
        for tap in result.tapGestures where tap.id == "browser.item" {
            #expect(tap.rect.width > 0 && tap.rect.height > 0)
        }
    }
}

@Test @XUIActor
func theStripScrollsHorizontally() async throws {
    let fixture = try await Fixture(files: (0..<200).map { "f\($0).png" })
    defer { fixture.cleanup() }
    let model = FileBrowserModel(workspace: fixture.workspace)
    model.open(.folder(id: fixture.folderID, path: ""))
    await model.reload()
    let (_, result) = await render(model, size: Size(width: 900, height: 140))
    let rects = result.tapGestures.filter { $0.id == "browser.item" }.map(\.rect)
    #expect(Set(rects.map(\.y)).count == 1) // one track: every item shares a row
    #expect(rects.map(\.x) == rects.map(\.x).sorted())
}

@Test
func folderModeChoosesTheCurrentFolder() async throws {
    let fixture = try await Fixture(files: [], folders: ["Project A"])
    defer { fixture.cleanup() }
    let chosen = Recorder()
    let model = FileBrowserModel(workspace: fixture.workspace)
    model.onChooseFolder = { _, path in chosen.add(path) }
    #expect(model.snapshot().choosesFolders)
    model.open(.folder(id: fixture.folderID, path: "Project A"))
    await model.reload()
    model.chooseCurrentFolder()
    #expect(chosen.all == ["Project A"])
}

@Test @XUIActor
func searchRowFiltersAsYouType() async throws {
    let fixture = try await Fixture(files: ["alpha.png", "alphabet.txt", "beta.png"])
    defer { fixture.cleanup() }
    let model = FileBrowserModel(workspace: fixture.workspace)
    model.open(.folder(id: fixture.folderID, path: ""))
    await model.reload()
    let focus = TextFocusStore()
    let state = StateStore()
    func render() async -> RenderResult {
        await LayoutHost(canvas: Size(width: 600, height: 400)).render(
            FileBrowserView(model: model).environment(focus), into: RecordingSurface(), store: state)
    }

    var result = await render()
    #expect(result.tapGestures.contains { $0.id == "browser.search.open" })
    #expect(!result.tapGestures.contains { $0.id == "browser.search" })

    // Opening the search row focuses its field so the keyboard can appear at once.
    model.setSearching(true)
    result = await render()
    #expect(focus.focusedID == "browser.search")

    focus.send(.insert("alp"))
    #expect(model.queryText == "alp")
    #expect(model.snapshot().visible.count == 2)

    focus.send(.insert("ha."))
    #expect(model.snapshot().visible.count == 1)

    // Closing the row clears the query and shows everything again.
    model.setSearching(false)
    #expect(model.queryText.isEmpty)
    #expect(model.snapshot().visible.count == 3)
    result = await render()
    #expect(result.tapGestures.contains { $0.id == "browser.search.open" })
}
