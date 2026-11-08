import Foundation
import XCTest
import XDocument

private struct Model: Codable, Sendable, Equatable { var value: Int = 0 }

@MainActor
private final class TestLease: DocumentFolderAccess {
    var released = false
    func releaseAccess() { released = true }
}

@MainActor
private final class TestEnvironment: DocumentProjectEnvironment {
    let root: URL
    var remembered: URL?
    var restoredPage = ""
    var leases: [TestLease] = []
    init(root: URL) { self.root = root }
    func defaultFolder() throws -> URL { root }
    func restoredFolder() throws -> URL? { remembered }
    func acquire(folder: URL) throws -> any DocumentFolderAccess {
        let lease = TestLease(); leases.append(lease); return lease
    }
    func remember(folder: URL) throws { remembered = folder }
}

@MainActor
final class DocumentProjectControllerTests: XCTestCase {
    func testCreateEditSwitchAndRestore() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = base.appendingPathComponent("first"), second = base.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let environment = TestEnvironment(root: first)
        let controller = DocumentProjectController(environment: environment, filename: ".example", initial: { Model() })
        await controller.start()
        XCTAssertEqual(controller.state.folder, first)
        controller.edit("change") { $0.value = 42 }
        XCTAssertEqual(controller.state.document?.value, 42)
        try await controller.open(folder: second)
        XCTAssertTrue(environment.leases[0].released)
        XCTAssertEqual(controller.state.document?.value, 0)
        controller.navigate(to: "settings")
        let restored = DocumentProjectController(environment: environment, filename: ".example", initial: { Model() })
        await restored.start()
        XCTAssertEqual(restored.state.folder, second)
        XCTAssertEqual(restored.state.page, "settings")
        try await restored.open(folder: first)
        XCTAssertEqual(restored.state.document?.value, 42)
    }

    func testFailedSavePreventsSwitchAndPreservesCurrentProject() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = base.appendingPathComponent("first"), second = base.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let environment = TestEnvironment(root: first)
        let controller = DocumentProjectController(environment: environment, filename: ".example", initial: { Model() })
        await controller.start()
        try Data("outside".utf8).write(to: first.appendingPathComponent(".example"))
        controller.edit("change") { $0.value = 5 }
        do { try await controller.open(folder: second); XCTFail("Expected conflict") }
        catch { XCTAssertEqual(error as? DocumentSessionError, .externalModification) }
        XCTAssertEqual(controller.state.folder, first)
        XCTAssertEqual(controller.state.document?.value, 5)
        XCTAssertFalse(environment.leases[0].released)
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent(".example")), Data("outside".utf8))
    }
}
