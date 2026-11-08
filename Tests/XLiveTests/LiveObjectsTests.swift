import Foundation
import XCTest
import XLive

private actor TestLiveRoot: LiveRoot {
    let rootObject = LiveObject(id: .init(rawValue: "root"), key: "", name: "Root", kind: "root", mayHaveChildren: true)
    let parameter = LiveObject(id: .init(rawValue: "node-1:opacity"), key: "opacity", name: "Opacity", kind: "parameter", value: .init(kind: .number, isWritable: true, minimum: 0, maximum: 1))
    var value = LiveValue.number(0.5)
    func root() async throws -> LiveObject { rootObject }
    func object(id: LiveObjectID) async throws -> LiveObject {
        if id == rootObject.id { return rootObject }
        if id == parameter.id { return parameter }
        throw LiveAccessError.notFound
    }
    func children(of id: LiveObjectID) async throws -> [LiveObject] {
        if id == rootObject.id { return [parameter] }
        if id == parameter.id { return [] }
        throw LiveAccessError.notFound
    }
    func read(id: LiveObjectID) async throws -> LiveValue {
        guard id == parameter.id else { throw LiveAccessError.notFound }
        return value
    }
    func write(id: LiveObjectID, value: LiveValue) async throws {
        guard id == parameter.id else { throw LiveAccessError.notFound }
        guard case .number(let number) = value, (0...1).contains(number) else { throw LiveAccessError.invalidValue }
        self.value = value
    }
}

final class LiveObjectsTests: XCTestCase {
    func testResolveReadAndWrite() async throws {
        let provider = TestLiveRoot()
        let resolved = try await provider.resolve(LivePath("/opacity"))
        XCTAssertEqual(resolved.name, "Opacity")
        try await provider.write(id: resolved.id, value: .number(0.75))
        let value = try await provider.read(id: resolved.id)
        XCTAssertEqual(value, .number(0.75))
        do { try await provider.write(id: resolved.id, value: .number(2)); XCTFail("Expected invalid value") }
        catch { XCTAssertEqual(error as? LiveAccessError, .invalidValue) }
        do { _ = try await provider.resolve(LivePath("/missing")); XCTFail("Expected missing object") }
        catch { XCTAssertEqual(error as? LiveAccessError, .notFound) }
    }
    func testPathValidationAndSerialization() throws {
        for path in ["relative", "/a/../b", "/a//b", "/a/", "/a/./b"] {
            XCTAssertThrowsError(try LivePath(path))
        }
        let path = try LivePath("/composition/node-1/opacity")
        XCTAssertEqual(try JSONDecoder().decode(LivePath.self, from: JSONEncoder().encode(path)), path)
        XCTAssertThrowsError(try JSONDecoder().decode(LivePath.self, from: Data("\"/a/../b\"".utf8)))
        let value = LiveValue.object(["source": .reference(.init(rawValue: "node-1")), "value": .number(0.5)])
        XCTAssertEqual(try JSONDecoder().decode(LiveValue.self, from: JSONEncoder().encode(value)), value)
    }
}
