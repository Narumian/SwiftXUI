import Foundation
import Testing
@testable import X

private protocol TestPayloadProtocol: AnyCodable {}

private struct TestPayload: TestPayloadProtocol, Equatable {
    let value: Int
}

private struct OtherPayload: AnyCodable, Equatable {
    let name: String
}

@AnyCodableRegistry([TestPayload.self, OtherPayload.self])
private enum TestCatalog {}

@Test
func aoxRoundTripsTheRegisteredConcreteType() throws {
    let original = Aox<TestCatalog, TestPayload>(wrappedValue: TestPayload(value: 42))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(
        Aox<TestCatalog, TestPayload>.self,
        from: data
    )

    #expect(decoded.wrappedValue as? TestPayload == TestPayload(value: 42))
}

@Test
func aoxWritesTheTypeDiscriminator() throws {
    let data = try JSONEncoder().encode(
        Aox<TestCatalog, OtherPayload>(wrappedValue: OtherPayload(name: "hello"))
    )

    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["typeID"] as? String == OtherPayload.typeID)
}

@Test
func aoxRoundTripsOptionalNil() throws {
    let original = Aox<TestCatalog, TestPayload?>(wrappedValue: nil)

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(
        Aox<TestCatalog, TestPayload?>.self,
        from: data
    )

    #expect(decoded.wrappedValue == nil)
}

@Test
func aoxRoundTripsOptionalValue() throws {
    let original = Aox<TestCatalog, TestPayload?>(
        wrappedValue: TestPayload(value: 7)
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(
        Aox<TestCatalog, TestPayload?>.self,
        from: data
    )

    #expect(decoded.wrappedValue == TestPayload(value: 7))
}

@Test
func aoxRoundTripsOptionalErasedValue() throws {
    let original = Aox<TestCatalog, (any TestPayloadProtocol)?>(
        wrappedValue: TestPayload(value: 11)
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(
        Aox<TestCatalog, (any TestPayloadProtocol)?>.self,
        from: data
    )

    #expect(decoded.wrappedValue as? TestPayload == TestPayload(value: 11))
}
