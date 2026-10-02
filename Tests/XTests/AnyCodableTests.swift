import Foundation
import Testing
@testable import X

private struct TestPayload: AnyCodable, Equatable {
    let value: Int
}

private struct OtherPayload: AnyCodable, Equatable {
    let name: String
}

@AnyCodableRegistry([TestPayload.self, OtherPayload.self])
private enum TestCatalog {}

@Test
func aoxRoundTripsTheRegisteredConcreteType() throws {
    let original = Aox<TestCatalog>(wrappedValue: TestPayload(value: 42))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Aox<TestCatalog>.self, from: data)

    #expect(decoded.wrappedValue as? TestPayload == TestPayload(value: 42))
}

@Test
func aoxWritesTheTypeDiscriminator() throws {
    let data = try JSONEncoder().encode(
        Aox<TestCatalog>(wrappedValue: OtherPayload(name: "hello"))
    )

    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["typeID"] as? String == OtherPayload.typeID)
}
