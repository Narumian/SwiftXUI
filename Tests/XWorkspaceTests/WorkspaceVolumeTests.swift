import Foundation
import XCTest
@testable import XWorkspace

/// A volume with no directory behind it: files by path, kept in memory.
private struct MemoryVolume: WorkspaceVolume {
    var files: [String: Data]

    func list(folderID: UUID, path: String) throws -> [WorkspaceEntry] {
        let prefix = path.isEmpty ? "" : path + "/"
        guard path.isEmpty || files.keys.contains(where: { $0.hasPrefix(prefix) }) else { throw WorkspaceError.invalidPath }
        var seen = Set<String>()
        var entries: [WorkspaceEntry] = []
        for (key, data) in files.sorted(by: { $0.key < $1.key }) where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                let directory = prefix + rest[..<slash]
                if seen.insert(directory).inserted { entries.append(WorkspaceEntry(folderID: folderID, path: directory, kind: .directory)) }
            } else {
                entries.append(WorkspaceEntry(folderID: folderID, path: key, kind: .file, size: Int64(data.count)))
            }
        }
        return entries
    }
    func stamp(path: String) throws -> WorkspaceStamp? { WorkspaceStamp(rawValue: Int64(files.count)) }
    func read(path: String) throws -> Data {
        guard let data = files[path] else { throw WorkspaceError.invalidPath }
        return data
    }
}

final class WorkspaceVolumeTests: XCTestCase {
    private let builtin = UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!

    private func workspace() async throws -> Workspace {
        let workspace = try Workspace(access: LocalWorkspaceAccessProvider())
        let volume = MemoryVolume(files: ["shapes/circle.txt": Data("c".utf8), "shapes/square.txt": Data("s".utf8), "about.txt": Data("hi".utf8)])
        try await workspace.mount(volume, id: builtin, name: "builtin")
        return workspace
    }

    func testAMountedVolumeListsAndReadsLikeAFolder() async throws {
        let workspace = try await workspace()
        let folders = await workspace.folders()
        XCTAssertEqual(folders.map(\.name), ["builtin"])
        XCTAssertEqual(folders.first?.id, builtin)
        XCTAssertEqual(folders.first?.isReadOnly, true)

        let root = try await workspace.list(folderID: builtin)
        XCTAssertEqual(root.map(\.path), ["about.txt", "shapes"])
        XCTAssertEqual(root.map(\.kind), [.file, .directory])
        let shapes = try await workspace.list(folderID: builtin, path: "shapes")
        XCTAssertEqual(shapes.map(\.name), ["circle.txt", "square.txt"])
        let data = try await workspace.read(folderID: builtin, path: "shapes/circle.txt")
        XCTAssertEqual(data, Data("c".utf8))
        let stamp = try await workspace.directoryStamp(folderID: builtin)
        XCTAssertEqual(stamp, WorkspaceStamp(rawValue: 3))
    }

    func testAMountedVolumeIsReachableByNameURL() async throws {
        let workspace = try await workspace()
        let data = try await workspace.read(WorkspaceURL("xw://builtin/about.txt")!)
        XCTAssertEqual(data, Data("hi".utf8))
        let resolved = try await workspace.resolve(WorkspaceURL("xw://builtin/shapes/square.txt")!)
        XCTAssertEqual(resolved, WorkspaceURL(folderID: builtin, path: "shapes/square.txt"))
    }

    func testAReadOnlyVolumeRefusesChangesAndIsNotSaved() async throws {
        let workspace = try await workspace()
        do { try await workspace.write(folderID: builtin, path: "x.txt", data: Data()); XCTFail("Expected read-only") }
        catch { XCTAssertEqual(error as? WorkspaceError, .readOnly) }
        do { _ = try await workspace.move(folderID: builtin, path: "about.txt", toDirectory: "shapes"); XCTFail("Expected read-only") }
        catch { XCTAssertEqual(error as? WorkspaceError, .readOnly) }
        do { _ = try await workspace.lease(folderID: builtin); XCTFail("Expected unsupported") }
        catch { XCTAssertEqual(error as? WorkspaceError, .unsupportedItem) }
        do { try await workspace.reconnect(folderID: builtin, directory: FileManager.default.temporaryDirectory); XCTFail("Expected unsupported") }
        catch { XCTAssertEqual(error as? WorkspaceError, .unsupportedItem) }
        let saved = await workspace.snapshot()
        XCTAssertTrue(saved.isEmpty)
    }

    func testMountedAndRegisteredFoldersLiveSideBySide() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let workspace = try await workspace()
        let disk = try await workspace.register(directory: base, name: "Shows")
        let saved = await workspace.snapshot()
        XCTAssertEqual(saved.map(\.folder.id), [disk.id])
        let folders = await workspace.folders()
        XCTAssertEqual(folders.map(\.name), ["builtin", "Shows"])
        do { try await workspace.mount(MemoryVolume(files: [:]), id: builtin, name: "again"); XCTFail("Expected a duplicate id") }
        catch { XCTAssertEqual(error as? WorkspaceError, .invalidFolder) }
        try await workspace.remove(folderID: builtin)
        let remaining = await workspace.folders()
        XCTAssertEqual(remaining.map(\.name), ["Shows"])
    }

    func testADirectoryCanBeMountedReadOnly() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data([7]).write(to: base.appendingPathComponent("a.bin"))
        let workspace = try Workspace(access: LocalWorkspaceAccessProvider())
        let access = LocalWorkspaceAccessProvider()
        let volume = DiskVolume(access: access, token: try access.register(directory: base))
        let id = UUID()
        let folder = try await workspace.mount(volume, id: id, name: "bundle", readOnly: true)
        XCTAssertTrue(folder.isReadOnly)
        let data = try await workspace.read(folderID: id, path: "a.bin")
        XCTAssertEqual(data, Data([7]))
        do { try await workspace.write(folderID: id, path: "b.bin", data: Data()); XCTFail("Expected read-only") }
        catch { XCTAssertEqual(error as? WorkspaceError, .readOnly) }
    }

    func testProvidedVolumesComeFirstAndWinTheirNameOverARegisteredFolder() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let theirs = base.appendingPathComponent("builtin")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data([9]).write(to: theirs.appendingPathComponent("about.txt"))
        let provided = WorkspaceMount(id: builtin, name: "builtin", volume: MemoryVolume(files: ["about.txt": Data("hi".utf8)]), readOnly: true)
        let workspace = try Workspace(access: LocalWorkspaceAccessProvider(), provided: [provided])
        let user = try await workspace.register(directory: theirs)       // same name as the provided volume
        let folders = await workspace.folders()
        XCTAssertEqual(folders.map(\.id), [builtin, user.id])

        // The name reaches the app's own volume; the user's folder is still reachable by its UUID.
        let byName = try await workspace.read(WorkspaceURL("xw://builtin/about.txt")!)
        XCTAssertEqual(byName, Data("hi".utf8))
        let byID = try await workspace.read(WorkspaceURL(folderID: user.id, path: "about.txt"))
        XCTAssertEqual(byID, Data([9]))
        // Only the registered directory is saved.
        let saved = await workspace.snapshot()
        XCTAssertEqual(saved.map(\.folder.id), [user.id])
        // Restoring puts the provided volume back in front.
        let restored = try Workspace(access: LocalWorkspaceAccessProvider(), registrations: saved, provided: [provided])
        let restoredFolders = await restored.folders()
        XCTAssertEqual(restoredFolders.map(\.id), [builtin, user.id])
    }

    func testProvidedVolumesNeedDistinctIDsAndNames() throws {
        let one = WorkspaceMount(id: builtin, name: "a", volume: MemoryVolume(files: [:]))
        XCTAssertThrowsError(try Workspace(access: LocalWorkspaceAccessProvider(), provided: [one, one]))
        let sameName = WorkspaceMount(id: UUID(), name: "a", volume: MemoryVolume(files: [:]))
        XCTAssertThrowsError(try Workspace(access: LocalWorkspaceAccessProvider(), provided: [one, sameName]))
    }

    func testDiskVolumeFromADirectoryRejectsAFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try DiskVolume(directory: file)) { XCTAssertEqual($0 as? WorkspaceError, .invalidFolder) }
    }
}
