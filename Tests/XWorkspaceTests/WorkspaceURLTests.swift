import Foundation
import XCTest
@testable import XWorkspace

final class WorkspaceURLTests: XCTestCase {
    private let id = UUID(uuidString: "3F2A8C1E-0000-4000-8000-000000000001")!

    func testUUIDFormRoundTrips() throws {
        let url = WorkspaceURL(folderID: id, path: "media/Intro Reel.svg")
        XCTAssertEqual(url.description, "xw://3F2A8C1E-0000-4000-8000-000000000001/media/Intro%20Reel.svg")
        XCTAssertEqual(WorkspaceURL(url.description), url)
        XCTAssertEqual(WorkspaceURL(url: url.url), url)
        XCTAssertEqual(url.folderID, id)
    }

    func testNamesMayBePlainOrPercentEncoded() {
        XCTAssertEqual(WorkspaceURL("xw://Shows/a.svg"), WorkspaceURL(volume: .name("Shows"), path: "a.svg"))
        XCTAssertEqual(WorkspaceURL("xw://ショー/シーン 1/a.svg"), WorkspaceURL(volume: .name("ショー"), path: "シーン 1/a.svg"))
        XCTAssertEqual(WorkspaceURL("xw://My%20Shows/a.svg"), WorkspaceURL(volume: .name("My Shows"), path: "a.svg"))
        // What is written back is ASCII, and `url` does not turn the name into punycode.
        let url = WorkspaceURL(volume: .name("ショー"), path: "a b.svg")
        XCTAssertEqual(url.description, "xw://%E3%82%B7%E3%83%A7%E3%83%BC/a%20b.svg")
        XCTAssertEqual(WorkspaceURL(url: url.url), url)
    }

    func testRootAndTrailingSlash() {
        XCTAssertEqual(WorkspaceURL("xw://Shows")?.path, "")
        XCTAssertEqual(WorkspaceURL("xw://Shows/")?.path, "")
        XCTAssertEqual(WorkspaceURL("xw://Shows/media/")?.path, "media")
        XCTAssertEqual(WorkspaceURL(volume: .name("Shows")).description, "xw://Shows")
    }

    func testInvalidTextIsRejected() {
        for text in ["http://Shows/a", "xw:///a", "xw://", "xw://Shows/../a", "xw://Shows/./a", "xw://Shows/a//b",
                     "xw://Shows/a%2Fb", "xw://Shows/%ZZ", "Shows/a"] {
            XCTAssertNil(WorkspaceURL(text), text)
        }
    }

    func testCodableIsTheURLText() throws {
        let url = WorkspaceURL(folderID: id, path: "a.ild")
        let data = try JSONEncoder().encode([url])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["xw:\/\/3F2A8C1E-0000-4000-8000-000000000001\/a.ild"]"#)
        XCTAssertEqual(try JSONDecoder().decode([WorkspaceURL].self, from: data), [url])
        XCTAssertThrowsError(try JSONDecoder().decode([WorkspaceURL].self, from: Data(#"["nope"]"#.utf8)))
    }

    func testEntryURL() {
        let entry = WorkspaceEntry(folderID: id, path: "media/a.png", kind: .file)
        XCTAssertEqual(entry.url, WorkspaceURL(folderID: id, path: "media/a.png"))
    }

    func testNamesResolveToTheFolderID() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let shows = base.appendingPathComponent("Shows"), other = base.appendingPathComponent("a/Assets"), again = base.appendingPathComponent("b/Assets")
        for directory in [shows, other, again] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let workspace = try Workspace(access: LocalWorkspaceAccessProvider())
        let showsFolder = try await workspace.register(directory: shows)
        _ = try await workspace.register(directory: other)
        _ = try await workspace.register(directory: again)
        try await workspace.write(folderID: showsFolder.id, path: "intro.bin", data: Data([1, 2]))

        let resolved = try await workspace.resolve(WorkspaceURL("xw://Shows/intro.bin")!)
        XCTAssertEqual(resolved, WorkspaceURL(folderID: showsFolder.id, path: "intro.bin"))
        let looser = try await workspace.resolve(WorkspaceURL("xw://shows/intro.bin")!)
        XCTAssertEqual(looser, resolved)
        let bytes = try await workspace.read(WorkspaceURL("xw://Shows/intro.bin")!)
        XCTAssertEqual(bytes, Data([1, 2]))

        do { _ = try await workspace.resolve(WorkspaceURL("xw://Assets/x")!); XCTFail("Expected an ambiguous name") }
        catch { XCTAssertEqual(error as? WorkspaceError, .ambiguousName) }
        do { _ = try await workspace.resolve(WorkspaceURL("xw://Nowhere/x")!); XCTFail("Expected folderNotFound") }
        catch { XCTAssertEqual(error as? WorkspaceError, .folderNotFound) }
        do { _ = try await workspace.resolve(WorkspaceURL(folderID: UUID(), path: "x")); XCTFail("Expected folderNotFound") }
        catch { XCTAssertEqual(error as? WorkspaceError, .folderNotFound) }
    }
}
