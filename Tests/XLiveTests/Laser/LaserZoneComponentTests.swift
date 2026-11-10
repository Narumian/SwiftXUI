import Foundation
import simd
import XCTest
@testable import XLive

final class LaserZoneComponentTests: XCTestCase {
    func testAZoneIsAnXLiveValueThatEncodesWhatASavedSessionNeeds() throws {
        let zone = LaserZone(id: UUID(), scanner: LaserScannerSettings(paddingDwell: 5, cornerDwell: 2), maximumPointRate: 40_000)
        let component: any XLive = zone
        XCTAssertNotNil(component)
        let back = try JSONDecoder().decode(LaserZone.self, from: JSONEncoder().encode(zone))
        XCTAssertEqual(back, zone)
        XCTAssertEqual(back.scanner.paddingDwell, 5)
        XCTAssertEqual(back.maximumPointRate, 40_000)
    }

    func testUpdateRunsAndTheRateNeverDropsBelowOne() async {
        var zone = LaserZone(maximumPointRate: 0)
        await zone.update(context: LiveUpdateContext(deltaTime: 0.016))
        XCTAssertEqual(zone.maximumPointRate, 1)
    }

    func testPublishPutsTheZoneIntoTheBoxesAChainReads() {
        var zone = LaserZone()
        zone.scanner.maximumStep = 0.123
        let scanner = LaserLive(LaserScannerSettings()), mastering = LaserLive(LaserMastering())
        zone.publish(scanner: scanner, mastering: mastering)
        XCTAssertEqual(scanner.value.maximumStep, 0.123)
        XCTAssertEqual(mastering.value, zone.mastering)
    }

    func testAChainFollowsTheSettingsAZonePublishes() {
        var camera = matrix_identity_double4x4
        camera.columns.3 = SIMD4(0, 0, 2, 1)
        let projection = LaserProjection(camera: camera, projection: LaserProjection.perspective(fovxDegrees: 90, near: 0.1, far: 50))
        let looper = FixedFrame([TestShape(id: 1, vertices: [LaserVertex(x: -0.5, y: 0), LaserVertex(x: 0.5, y: 0)])])
        var zone = LaserZone(scanner: LaserScannerSettings(paddingDwell: 0, paddingBlank: 0, cornerDwell: 0, maximumStep: 0.2))
        let scanner = LaserLive(zone.scanner), mastering = LaserLive(zone.mastering)
        var chain = LaserScannerChain(looper, projection: projection, live: scanner, mastering: mastering, rate: zone.maximumPointRate)
        _ = chain.read()
        let sparse = chain.read().flatMap(\.points).count
        zone.scanner.maximumStep = 0.01
        zone.publish(scanner: scanner, mastering: mastering)
        _ = chain.read()
        let dense = chain.read().flatMap(\.points).count
        XCTAssertGreaterThan(dense, sparse)
        XCTAssertEqual(chain.rate, 30_000)
    }
}
