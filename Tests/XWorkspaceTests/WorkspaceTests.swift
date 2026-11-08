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
}
