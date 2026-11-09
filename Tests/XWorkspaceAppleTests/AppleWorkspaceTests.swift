import Foundation
import XCTest
import XWorkspace
import XWorkspaceApple

final class AppleWorkspaceTests: XCTestCase {
    func testBookmarkRestorationAndCoordinatedAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(access: AppleWorkspaceAccessProvider(), coordinator: AppleWorkspaceFileCoordinator())
        let folder = try await workspace.register(directory: root)
        try await workspace.write(folderID: folder.id, path: "test.txt", data: Data("hello".utf8))
        let snapshot = try JSONEncoder().encode(await workspace.snapshot())
        let restored = try Workspace(access: AppleWorkspaceAccessProvider(), coordinator: AppleWorkspaceFileCoordinator(), registrations: JSONDecoder().decode([WorkspaceRegistration].self, from: snapshot))
        let entries = try await restored.list(folderID: folder.id)
        XCTAssertEqual(entries.map(\.path), ["test.txt"])
        let data = try await restored.read(folderID: folder.id, path: "test.txt")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello")
    }

    /// The resolved URL is kept between operations. A folder moved after that must not go on being served
    /// from the old path: the bookmark is resolved again and reports itself stale, as it always has.
    func testAMovedFolderIsNotServedFromTheKeptURL() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = base.appendingPathComponent("Shows"), moved = base.appendingPathComponent("Moved Shows")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let workspace = try Workspace(access: AppleWorkspaceAccessProvider(), coordinator: AppleWorkspaceFileCoordinator())
        let folder = try await workspace.register(directory: original)
        try await workspace.write(folderID: folder.id, path: "a.txt", data: Data("a".utf8))
        let first = try await workspace.list(folderID: folder.id)       // resolves the bookmark and keeps the URL
        XCTAssertEqual(first.map(\.path), ["a.txt"])
        let again = try await workspace.directoryStamp(folderID: folder.id)
        XCTAssertNotNil(again)

        try FileManager.default.moveItem(at: original, to: moved)
        for operation in 0..<2 {
            do { _ = try await workspace.list(folderID: folder.id); XCTFail("Expected a stale bookmark (\(operation))") }
            catch { XCTAssertEqual(error as? AppleWorkspaceAccessError, .staleBookmark) }
        }
        // Reconnecting to the new place works again.
        try await workspace.reconnect(folderID: folder.id, directory: moved)
        let afterReconnect = try await workspace.list(folderID: folder.id)
        XCTAssertEqual(afterReconnect.map(\.path), ["a.txt"])
    }
}
