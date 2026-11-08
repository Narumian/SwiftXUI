import Foundation
import XCTest
import XDocument

private struct Project: Codable, Sendable, Equatable {
    var title: String
    var count: Int
}

final class DocumentSessionTests: XCTestCase, @unchecked Sendable {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }

    func testCreateSaveEditUndoRedoAndReopen() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try DocumentSession<Project, LocalDocumentStorage>.create(Project(title: "Original", count: 0), at: url, storage: .init())
        let initial = await session.status()
        XCTAssertTrue(initial.isDirty)
        try await session.save()
        try await session.edit("Change", { $0.title = "Edited"; $0.count = 2 })
        let changed = await session.status()
        XCTAssertTrue(changed.isDirty)
        XCTAssertEqual(changed.undoName, "Change")
        try await session.undo()
        let undone = await session.status()
        XCTAssertFalse(undone.isDirty)
        XCTAssertEqual(undone.redoName, "Change")
        try await session.redo()
        let redone = try await session.document()
        XCTAssertEqual(redone, Project(title: "Edited", count: 2))
        try await session.save()
        try await session.close()
        let reopened = try DocumentSession<Project, LocalDocumentStorage>.open(at: url, storage: .init())
        let document = try await reopened.document()
        XCTAssertEqual(document, redone)
        let status = await reopened.status()
        XCTAssertFalse(status.isDirty)
        XCTAssertFalse(status.canUndo)
    }

    func testBranchingNoOpAndFailedEdit() async throws {
        enum Failure: Error { case failed }
        let session = try DocumentSession<Project, LocalDocumentStorage>.create(Project(title: "A", count: 0), at: temporaryURL(), storage: .init())
        try await session.edit("first") { $0.count = 1 }
        try await session.edit("second") { $0.count = 2 }
        try await session.undo()
        let noChange = try await session.edit("no-op") { _ in }
        XCTAssertFalse(noChange)
        do {
            try await session.edit("failed") { value in value.count = 99; throw Failure.failed }
            XCTFail("Expected failure")
        } catch Failure.failed {} 
        let beforeBranch = try await session.document()
        XCTAssertEqual(beforeBranch.count, 1)
        let status = await session.status()
        XCTAssertTrue(status.canRedo)
        try await session.edit("branch") { $0.count = 3 }
        let branched = await session.status()
        XCTAssertFalse(branched.canRedo)
        XCTAssertEqual(branched.undoName, "branch")
    }

    func testConflictAndClosePreserveUnsavedChanges() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try DocumentSession<Project, LocalDocumentStorage>.create(Project(title: "A", count: 0), at: url, storage: .init())
        try await session.save()
        try await session.edit("edit") { $0.count = 1 }
        try Data("external".utf8).write(to: url)
        do { try await session.save(); XCTFail("Expected conflict") }
        catch { XCTAssertEqual(error as? DocumentSessionError, .externalModification) }
        do { try await session.close(); XCTFail("Expected unsaved changes") }
        catch { XCTAssertEqual(error as? DocumentSessionError, .unsavedChanges) }
        let status = await session.status()
        XCTAssertTrue(status.isDirty)
        XCTAssertTrue(status.canUndo)
        try await session.close(discardChanges: true)
        do { _ = try await session.document(); XCTFail("Expected closed") }
        catch { XCTAssertEqual(error as? DocumentSessionError, .closed) }
        XCTAssertEqual(try Data(contentsOf: url), Data("external".utf8))
    }

    func testSavePointOnDiscardedHistoryBranch() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try DocumentSession<Project, LocalDocumentStorage>.create(Project(title: "A", count: 0), at: url, storage: .init())
        try await session.save()
        try await session.edit("one") { $0.count = 1 }
        try await session.save()
        try await session.undo()
        try await session.edit("other") { $0.count = 1 }
        let state = await session.status()
        XCTAssertTrue(state.isDirty)
        XCTAssertFalse(state.canRedo)
    }

    func testNewDocumentDoesNotOverwriteExistingFile() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("existing".utf8).write(to: url)
        let session = try DocumentSession<Project, LocalDocumentStorage>.create(Project(title: "A", count: 0), at: url, storage: .init())
        do { try await session.save(); XCTFail("Expected conflict") }
        catch { XCTAssertEqual(error as? DocumentSessionError, .externalModification) }
        XCTAssertEqual(try Data(contentsOf: url), Data("existing".utf8))
    }

    func testInteractiveGroupCommitCancelAndNoOp() async throws {
        let session = try DocumentSession<Project, LocalDocumentStorage>.create(Project(title: "A", count: 0), at: temporaryURL(), storage: .init())
        try await session.edit("previous") { $0.count = 1 }
        try await session.beginEditGroup("drag")
        try await session.updateEditGroup { $0.count = 2 }
        try await session.updateEditGroup { $0.count = 3 }
        let during = try await session.document()
        XCTAssertEqual(during.count, 3)
        do { try await session.save(); XCTFail("Expected active group") }
        catch { XCTAssertEqual(error as? DocumentSessionError, .editInProgress) }
        try await session.endEditGroup()
        try await session.undo()
        let undone = try await session.document()
        XCTAssertEqual(undone.count, 1)
        try await session.beginEditGroup("cancel")
        try await session.updateEditGroup { $0.count = 50 }
        try await session.cancelEditGroup()
        let cancelled = await session.status()
        XCTAssertTrue(cancelled.canRedo)
        try await session.beginEditGroup("unchanged")
        try await session.updateEditGroup { $0.count = 5 }
        try await session.updateEditGroup { $0.count = 1 }
        try await session.endEditGroup()
        let unchanged = await session.status()
        XCTAssertEqual(unchanged.redoName, "drag")
        XCTAssertEqual(unchanged.undoName, "previous")
    }

    func testCustomFileCodecAndHistory() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let codec = DocumentCodec<Project>(encode: { try PropertyListEncoder().encode($0) },
                                           decode: { try PropertyListDecoder().decode(Project.self, from: $0) })
        let session = try DocumentSession<Project, LocalDocumentStorage>.create(Project(title: "A", count: 0), at: url, storage: .init(), codec: codec)
        try await session.save()
        try await session.edit("edit") { $0.count = 4 }
        try await session.save()
        let reopened = try DocumentSession<Project, LocalDocumentStorage>.open(at: url, storage: .init(), codec: codec)
        let project = try await reopened.document()
        XCTAssertEqual(project.count, 4)
        try await session.undo()
        let undone = try await session.document()
        XCTAssertEqual(undone.count, 0)
    }
}
