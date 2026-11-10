import Foundation
import Testing
import XWorkspace
@testable import XWorkspaceUI

private final class Picks: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

private struct TreeFixture {
    let base: URL
    let workspace: Workspace
    let folderID: UUID

    init() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        for folder in ["Shaders", "Shaders/Old", "Footage"] {
            try fm.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["readme.txt", "Shaders/plasma.fs", "Shaders/Old/tunnel.fs", "Footage/loop.mov"] {
            try Data([1]).write(to: base.appendingPathComponent(file))
        }
        workspace = try Workspace(access: LocalWorkspaceAccessProvider())
        folderID = try await workspace.register(directory: base, name: "Media").id
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

private func names(_ model: FileTreeModel) -> [String] { model.snapshot().rows.map { String(repeating: "  ", count: $0.depth) + $0.item.name } }

/// Opening a folder loads it on a task; wait for the rows to settle.
private func settle(_ model: FileTreeModel, rows: Int) async {
    for _ in 0..<200 where model.snapshot().rows.count != rows { try? await Task.sleep(nanoseconds: 10_000_000) }
}

@Test
func treeShowsTheRootOpenAndNestsFoldersFirst() async throws {
    let fixture = try await TreeFixture()
    defer { fixture.cleanup() }
    let model = FileTreeModel(workspace: fixture.workspace, folderID: fixture.folderID)
    await model.reload()
    #expect(names(model) == ["Media", "  Footage", "  Shaders", "  readme.txt"])
}

@Test
func tappingAFolderOpensAndClosesItInPlace() async throws {
    let fixture = try await TreeFixture()
    defer { fixture.cleanup() }
    let model = FileTreeModel(workspace: fixture.workspace, folderID: fixture.folderID)
    await model.reload()

    model.activate(row: 2) // Shaders
    await settle(model, rows: 6)
    #expect(names(model) == ["Media", "  Footage", "  Shaders", "    Old", "    plasma.fs", "  readme.txt"])
    #expect(model.snapshot().rows[2].isExpanded)

    model.activate(row: 3) // Old
    await settle(model, rows: 7)
    #expect(names(model).contains("      tunnel.fs"))

    // Closing the parent hides everything under it; opening it again remembers the child.
    model.activate(row: 2)
    #expect(names(model) == ["Media", "  Footage", "  Shaders", "  readme.txt"])
    model.activate(row: 2)
    #expect(names(model).contains("      tunnel.fs"))
}

@Test
func tappingAFileSelectsAndPicksIt() async throws {
    let fixture = try await TreeFixture()
    defer { fixture.cleanup() }
    let picks = Picks()
    let model = FileTreeModel(workspace: fixture.workspace, folderID: fixture.folderID)
    model.onPick = { picks.add($0.path) }
    await model.reload()

    model.activate(row: 3) // readme.txt
    #expect(picks.all == ["readme.txt"])
    #expect(model.snapshot().selected?.path == "readme.txt")
}

@Test
func treeListsEveryRegisteredFolderAtTheTop() async throws {
    let fixture = try await TreeFixture()
    defer { fixture.cleanup() }
    let model = FileTreeModel(workspace: fixture.workspace)
    await model.reload()
    #expect(names(model) == ["Media"])
    model.activate(row: 0)
    await settle(model, rows: 4)
    #expect(names(model).first == "Media")
    #expect(model.snapshot().rows.count == 4)
}

@Test
func reloadKeepsWhatWasOpenAndSeesNewFiles() async throws {
    let fixture = try await TreeFixture()
    defer { fixture.cleanup() }
    let model = FileTreeModel(workspace: fixture.workspace, folderID: fixture.folderID)
    await model.reload()
    model.activate(row: 2)
    await settle(model, rows: 6)

    try Data([1]).write(to: fixture.base.appendingPathComponent("Shaders/new.fs"))
    await model.reload()
    #expect(names(model).contains("    new.fs"))
    #expect(model.snapshot().rows[2].isExpanded)
}

@Test
func foldersAcceptOnlyRealMoves() async throws {
    let fixture = try await TreeFixture()
    defer { fixture.cleanup() }
    let model = FileTreeModel(workspace: fixture.workspace, folderID: fixture.folderID)
    let id = fixture.folderID
    func entry(_ path: String, dir: Bool = false) -> WorkspaceEntry { WorkspaceEntry(folderID: id, path: path, kind: dir ? .directory : .file) }
    func key(_ path: String) -> FileTreeModel.NodeKey { .init(folderID: id, path: path) }

    // Folders take nothing until the app says what a drop does.
    #expect(!model.accepts(entry("readme.txt"), on: key("Shaders")))
    model.onDrop = { _, _ in true }
    #expect(model.accepts(entry("readme.txt"), on: key("Shaders")))
    // Already there, onto itself, into its own subtree, and a whole root are not moves.
    #expect(!model.accepts(entry("Shaders/plasma.fs"), on: key("Shaders")))
    #expect(!model.accepts(entry("Shaders", dir: true), on: key("Shaders")))
    #expect(!model.accepts(entry("Shaders", dir: true), on: key("Shaders/Old")))
    #expect(!model.accepts(entry("", dir: true), on: key("Shaders")))
    #expect(model.accepts(entry("Shaders/Old/tunnel.fs"), on: key("")))
}

@Test
func aDropCallsBackAndReloads() async throws {
    let fixture = try await TreeFixture()
    defer { fixture.cleanup() }
    let picks = Picks()
    let model = FileTreeModel(workspace: fixture.workspace, folderID: fixture.folderID)
    await model.reload()
    model.onDrop = { entry, destination in picks.add("\(entry.path)->\(destination.path)"); return true }
    let entry = model.snapshot().rows[3].item.entry // readme.txt
    #expect(model.drop(entry, on: .init(folderID: fixture.folderID, path: "Footage")))
    #expect(picks.all == ["readme.txt->Footage"])

    model.onDrop = { _, _ in false }
    #expect(!model.drop(entry, on: .init(folderID: fixture.folderID, path: "Footage")))
}

@Test
func aDropCanMoveTheFileOnDisk() async throws {
    let fixture = try await TreeFixture()
    defer { fixture.cleanup() }
    let model = FileTreeModel(workspace: fixture.workspace, folderID: fixture.folderID)
    model.movesOnDrop = true
    await model.reload()
    let entry = model.snapshot().rows[3].item.entry // readme.txt
    #expect(model.accepts(entry, on: .init(folderID: fixture.folderID, path: "Footage")))
    #expect(model.drop(entry, on: .init(folderID: fixture.folderID, path: "Footage")))
    await settle(model, rows: 5)
    #expect(names(model) == ["Media", "  Footage", "    loop.mov", "    readme.txt", "  Shaders"])
    #expect(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("Footage/readme.txt").path))
}

@Test
func aFailedMoveIsReportedAndLeavesTheTreeAlone() async throws {
    let fixture = try await TreeFixture()
    defer { fixture.cleanup() }
    try Data([1]).write(to: fixture.base.appendingPathComponent("Footage/readme.txt"))
    let errors = Picks()
    let model = FileTreeModel(workspace: fixture.workspace, folderID: fixture.folderID)
    model.movesOnDrop = true
    model.onError = { errors.add($0) }
    await model.reload()
    let entry = model.snapshot().rows[3].item.entry // readme.txt
    #expect(model.drop(entry, on: .init(folderID: fixture.folderID, path: "Footage")))
    for _ in 0..<200 where errors.all.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
    #expect(errors.all == ["Something with that name is already there"])
    #expect(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("readme.txt").path))
}

@Test
func choosingAFileTwiceLoadsItInsteadOfPickingAgain() async throws {
    let fixture = try await TreeFixture()
    defer { fixture.cleanup() }
    let picks = Picks()
    let loads = Picks()
    let model = FileTreeModel(workspace: fixture.workspace, folderID: fixture.folderID)
    model.onPick = { picks.add($0.path) }
    model.onLoad = { loads.add($0.path) }
    await model.reload()
    model.activate(row: 3, now: 100)      // readme.txt
    model.activate(row: 3, now: 100.2)
    #expect(picks.all == ["readme.txt"] && loads.all == ["readme.txt"])
    // Too late for a double, and a third choice starts over.
    model.activate(row: 3, now: 101)
    #expect(picks.all.count == 2 && loads.all.count == 1)

    // Without a load handler a second choice just picks again.
    let plain = FileTreeModel(workspace: fixture.workspace, folderID: fixture.folderID)
    let again = Picks()
    plain.onPick = { again.add($0.path) }
    await plain.reload()
    plain.activate(row: 3, now: 5); plain.activate(row: 3, now: 5.1)
    #expect(again.all.count == 2)
}

@Test
func theQueryKeepsMatchesAndTheFoldersAboveThemAndFindsUnopenedFolders() async throws {
    let fixture = try await TreeFixture()
    defer { fixture.cleanup() }
    let model = FileTreeModel(workspace: fixture.workspace, folderID: fixture.folderID)
    await model.reload()
    #expect(names(model) == ["Media", "  Footage", "  Shaders", "  readme.txt"])     // nothing below Shaders is listed yet

    model.setQuery("TUNNEL")
    await settle(model, rows: 4)
    #expect(names(model) == ["Media", "  Shaders", "    Old", "      tunnel.fs"])

    model.setQuery("zzz")
    #expect(names(model).isEmpty)
    model.setQuery("")
    #expect(names(model) == ["Media", "  Footage", "  Shaders", "  readme.txt"])      // the tree's own open state is untouched
}

@Test
func watchingListsTheTreeAgainWhenAFolderChanges() async throws {
    let fixture = try await TreeFixture()
    defer { fixture.cleanup() }
    let model = FileTreeModel(workspace: fixture.workspace, folderID: fixture.folderID)
    await model.reload()
    model.activate(row: 2)                 // Shaders
    await settle(model, rows: 6)
    await model.refreshIfChanged()
    #expect(names(model).count == 6)       // nothing moved, nothing changes

    try Data([1]).write(to: fixture.base.appendingPathComponent("Shaders/added.fs"))
    // The stamp of a folder can share a tick with the first write; give it a distinct one.
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: fixture.base.appendingPathComponent("Shaders").path)
    await model.refreshIfChanged()
    #expect(names(model).contains("    added.fs"))
}

private func selectedName(_ model: FileTreeModel) -> String? {
    let snapshot = model.snapshot()
    return snapshot.rows.first { $0.key == snapshot.selected }?.item.name
}

@Test
func theArrowKeysMoveTheSelectionWithoutPickingAndOpenAndCloseFolders() async throws {
    let fixture = try await TreeFixture()
    defer { fixture.cleanup() }
    let picks = Picks(), loads = Picks()
    let model = FileTreeModel(workspace: fixture.workspace, folderID: fixture.folderID)
    model.onPick = { picks.add($0.path) }
    model.onLoad = { loads.add($0.path) }
    await model.reload()                                    // Media, Footage, Shaders, readme.txt
    #expect(selectedName(model) == nil)

    model.moveSelection(by: 1)                              // nothing selected: down starts at the top
    #expect(selectedName(model) == "Media")
    model.moveSelection(by: 1); model.moveSelection(by: 1)
    #expect(selectedName(model) == "Shaders")
    model.moveSelection(by: 10)                             // stops at the end
    #expect(selectedName(model) == "readme.txt")
    #expect(picks.all.isEmpty)                              // moving over a file does not pick it
    #expect(model.snapshot().reveal?.item == 3)

    model.moveSelection(toLast: false)
    #expect(selectedName(model) == "Media")
    model.moveSelection(by: 2)                              // Shaders
    model.expandOrSelectFirstChild()                        // right: opens it
    await settle(model, rows: 6)
    #expect(names(model).contains("    plasma.fs"))
    #expect(selectedName(model) == "Shaders")
    model.expandOrSelectFirstChild()                        // right again: its first row
    #expect(selectedName(model) == "Old")
    model.collapseOrSelectParent()                          // left on a shut folder: the folder above
    #expect(selectedName(model) == "Shaders")
    model.collapseOrSelectParent()                          // left on an open folder: closes it
    #expect(names(model) == ["Media", "  Footage", "  Shaders", "  readme.txt"])

    model.moveSelection(by: 1)                              // readme.txt
    model.activateSelected()                                // return on a file loads it
    #expect(loads.all == ["readme.txt"] && picks.all == ["readme.txt"])     // as a click and a double click
    model.moveSelection(by: -1)                             // Shaders
    model.activateSelected()                                // return on a folder opens it
    await settle(model, rows: 6)
    #expect(model.snapshot().rows[2].isExpanded)
}
