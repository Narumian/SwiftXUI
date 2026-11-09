import Foundation
import XCTest
@testable import XWorkspace

final class WorkspaceTests: XCTestCase {
    func testMultipleRootsPersistenceAndFileOperations() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("first"), second = base.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let workspace = try Workspace(access: LocalWorkspaceAccessProvider())
        let a = try await workspace.register(directory: first)
        let b = try await workspace.register(directory: second, readOnly: true)
        try await workspace.write(folderID: a.id, path: "nested/test.bin", data: Data([0, 255]))
        let listing = try await workspace.list(folderID: a.id)
        XCTAssertEqual(listing.map(\.path), ["nested"])
        let data = try await workspace.read(folderID: a.id, path: "nested/test.bin")
        XCTAssertEqual(data, Data([0, 255]))
        do { try await workspace.write(folderID: b.id, path: "x", data: Data()); XCTFail("Expected read-only error") }
        catch { XCTAssertEqual(error as? WorkspaceError, .readOnly) }
        let encoded = try JSONEncoder().encode(await workspace.snapshot())
        let restored = try Workspace(access: LocalWorkspaceAccessProvider(), registrations: JSONDecoder().decode([WorkspaceRegistration].self, from: encoded))
        let folders = await restored.folders()
        XCTAssertEqual(folders.map(\.id), [a.id, b.id])
        let restoredData = try await restored.read(folderID: a.id, path: "nested/test.bin")
        XCTAssertEqual(restoredData, data)
    }

    func testTraversalAndSymlinksAreRejected() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: base)
        let workspace = try Workspace(access: LocalWorkspaceAccessProvider())
        let folder = try await workspace.register(directory: root)
        for path in ["../outside", "/outside", "link/outside"] {
            do { _ = try await workspace.read(folderID: folder.id, path: path); XCTFail("Expected invalid path: \(path)") }
            catch { XCTAssertEqual(error as? WorkspaceError, .invalidPath) }
        }
        let entries = try await workspace.list(folderID: folder.id)
        XCTAssertTrue(entries.isEmpty)
    }

    func testListingCarriesSizeExtensionAndDirectoryStamp() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let workspace = try Workspace(access: LocalWorkspaceAccessProvider())
        let folder = try await workspace.register(directory: base)
        try await workspace.write(folderID: folder.id, path: "Cue.Final.ILD", data: Data(repeating: 1, count: 12))
        let before = try await workspace.directoryStamp(folderID: folder.id)
        let listing = try await workspace.list(folderID: folder.id)
        let file = try XCTUnwrap(listing.first { $0.kind == .file })
        XCTAssertEqual(file.size, 12)
        XCTAssertEqual(file.fileExtension, "ild")
        XCTAssertNotNil(file.modified)
        XCTAssertEqual(listing.first { $0.kind == .directory }?.fileExtension, "")
        XCTAssertNil(listing.first { $0.kind == .directory }?.size)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await workspace.write(folderID: folder.id, path: "another.txt", data: Data())
        let after = try await workspace.directoryStamp(folderID: folder.id)
        XCTAssertNotEqual(before, after)
    }

    func testListingSkipsSymlinksAndKeepsHiddenFilesAndNestedPaths() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("deep/er"), withIntermediateDirectories: true)
        try Data([1, 2]).write(to: root.appendingPathComponent("deep/er/.hidden"))
        try Data([1]).write(to: root.appendingPathComponent("plain.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: base)
        let workspace = try Workspace(access: LocalWorkspaceAccessProvider())
        let folder = try await workspace.register(directory: root)
        let top = try await workspace.list(folderID: folder.id).map(\.name)
        XCTAssertEqual(top, ["deep", "plain.txt"])
        let nested = try await workspace.list(folderID: folder.id, path: "deep/er")
        XCTAssertEqual(nested.map(\.path), ["deep/er/.hidden"])
        XCTAssertEqual(nested.first?.size, 2)
        let unsorted = try await workspace.list(folderID: folder.id, sorted: false)
        XCTAssertEqual(Set(unsorted.map(\.name)), ["deep", "plain.txt"])
        do { _ = try await workspace.list(folderID: folder.id, path: "plain.txt"); XCTFail("a file is not a directory") } catch {}
    }

    func testLeaseKeepsARootUsableUntilReleased() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("project"), withIntermediateDirectories: true)
        let workspace = try Workspace(access: LocalWorkspaceAccessProvider())
        let folder = try await workspace.register(directory: base)
        let lease = try await workspace.lease(folderID: folder.id)
        XCTAssertEqual(lease.url(for: "project").lastPathComponent, "project")
        XCTAssertEqual(lease.url(for: "").path, lease.root.path)
        lease.release()
        lease.release()
    }

    func testMoveKeepsTheNameAndRefusesToOverwriteOrEnterItself() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        for dir in ["a/inner", "b"] { try FileManager.default.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true) }
        try Data([1]).write(to: base.appendingPathComponent("a/file.txt"))
        try Data([2]).write(to: base.appendingPathComponent("b/file.txt"))
        let workspace = try Workspace(access: LocalWorkspaceAccessProvider())
        let folder = try await workspace.register(directory: base)
        let readOnly = try await workspace.register(directory: base, readOnly: true)

        // Into a sibling directory, and out to the root.
        let moved = try await workspace.move(folderID: folder.id, path: "a/inner", toDirectory: "b")
        XCTAssertEqual(moved, "b/inner")
        let back = try await workspace.move(folderID: folder.id, path: "b/inner", toDirectory: "")
        XCTAssertEqual(back, "inner")

        // Same name already there.
        do { try await workspace.move(folderID: folder.id, path: "a/file.txt", toDirectory: "b"); XCTFail("expected a clash") }
        catch { XCTAssertEqual(error as? WorkspaceError, .alreadyExists) }
        // A directory cannot go into itself or its own subtree.
        do { try await workspace.move(folderID: folder.id, path: "a", toDirectory: "a/inner"); XCTFail("expected a refusal") }
        catch { XCTAssertEqual(error as? WorkspaceError, .invalidPath) }
        // Nor into a file, nor out of a read-only folder.
        do { try await workspace.move(folderID: folder.id, path: "inner", toDirectory: "b/file.txt"); XCTFail("expected a refusal") }
        catch { XCTAssertEqual(error as? WorkspaceError, .unsupportedItem) }
        do { try await workspace.move(folderID: readOnly.id, path: "inner", toDirectory: "b"); XCTFail("expected read-only") }
        catch { XCTAssertEqual(error as? WorkspaceError, .readOnly) }
    }
}

final class DirectoryScannerTests: XCTestCase {
    /// The bulk listing must see exactly what the `readdir` + `stat` listing sees.
    func testBulkAndReaddirListingsAgree() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        try fm.createDirectory(at: base.appendingPathComponent("sub dir/ネスト"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 12).write(to: base.appendingPathComponent("a.bin"))
        try Data().write(to: base.appendingPathComponent(".hidden"))
        try Data(repeating: 2, count: 70_000).write(to: base.appendingPathComponent("日本語 ファイル.ILD"))
        try fm.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: base.appendingPathComponent("a.bin"))
        mkfifo(base.appendingPathComponent("pipe").path, 0o644)
        for i in 0..<3000 { try Data([UInt8(i % 250)]).write(to: base.appendingPathComponent("many \(i).txt")) }

        func summary(_ entries: [(String, Bool, Int64, Date?)]) -> [String] {
            entries.map { "\($0.0)|\($0.1)|\($0.2)|\(String(format: "%.6f", $0.3?.timeIntervalSince1970 ?? -1))" }.sorted()
        }
        let bulk = try DirectoryScanner.scan(base) { ($0, $1, $2, $3) }
        let reference = try DirectoryScanner.scanWithReaddirForTesting(base) { ($0, $1, $2, $3) }
        XCTAssertEqual(summary(bulk), summary(reference))
        XCTAssertEqual(bulk.count, 3000 + 4)   // many*, a.bin, .hidden, 日本語, sub dir — no link, no fifo
        XCTAssertTrue(bulk.contains { $0.0 == "日本語 ファイル.ILD" && $0.2 == 70_000 })
        XCTAssertTrue(bulk.contains { $0.0 == "sub dir" && $0.1 && $0.2 == 0 })
        XCTAssertThrowsError(try DirectoryScanner.scan(base.appendingPathComponent("a.bin")) { ($0, $1, $2, $3) })
    }

    func testModificationOfAPath() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let found = try XCTUnwrap(DirectoryScanner.modification(of: base.path))
        XCTAssertTrue(found.isDirectory)
        XCTAssertNil(DirectoryScanner.modification(of: base.appendingPathComponent("missing").path))
    }
}
