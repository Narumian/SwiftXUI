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
}
