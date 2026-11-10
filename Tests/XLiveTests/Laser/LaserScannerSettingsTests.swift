import Foundation
import simd
import XCTest
@testable import XLive

final class LaserScannerSettingsTests: XCTestCase {
    func testACollectionSavedBeforeTheSettingsExistedStillLoadsWithDefaults() throws {
        let id = UUID()
        let old = #"{"outputs":[{"id":"\#(id.uuidString)","name":"Laser 01","device":"laserCube","address":"192.168.1.106","masks":{"masks":[]},"scanner":{"cornerDwell":3}}]}"#
        let collection = try JSONDecoder().decode(LaserOutputCollection.self, from: Data(old.utf8))
        XCTAssertEqual(collection.scanner, LaserScannerSettings())      // one set, not one per output
        XCTAssertEqual(collection.outputs.first?.address, "192.168.1.106")
        let saved = LaserOutputCollection(outputs: collection.outputs, scanner: LaserScannerSettings(cornerDwell: 5))
        XCTAssertEqual(try JSONDecoder().decode(LaserOutputCollection.self, from: JSONEncoder().encode(saved)), saved)
    }

    func testSettingsRoundTripAndMissingKeysKeepTheirDefaults() throws {
        let profile = LaserScannerSettings(paddingDwell: 5, paddingBlank: 2, screen: .cut, cornerDwell: 4, cornerThresholdDegrees: 35, maximumStep: 0.06, minimumStep: 0.01)
        XCTAssertEqual(try JSONDecoder().decode(LaserScannerSettings.self, from: JSONEncoder().encode(profile)), profile)
        let partial = try JSONDecoder().decode(LaserScannerSettings.self, from: Data(#"{"cornerDwell":2}"#.utf8))
        XCTAssertEqual(partial.cornerDwell, 2)
        XCTAssertEqual(partial.maximumStep, LaserScannerSettings().maximumStep)
    }

    func testParametersClampRoundAndReadBack() {
        var profile = LaserScannerSettings()
        LaserScannerParameter.cornerDwell.set(7.6, in: &profile)
        XCTAssertEqual(profile.cornerDwell, 8)
        LaserScannerParameter.paddingDwell.set(500, in: &profile)
        XCTAssertEqual(profile.paddingDwell, 100)
        LaserScannerParameter.maximumStep.set(-1, in: &profile)
        XCTAssertEqual(profile.maximumStep, 0.005)
        LaserScannerParameter.cornerThreshold.set(.nan, in: &profile)
        XCTAssertEqual(profile.cornerThresholdDegrees, 20)           // not finite: unchanged
        LaserScannerParameter.cornerThreshold.setNormalized(0.5, in: &profile)
        XCTAssertEqual(profile.cornerThresholdDegrees, 45)
        XCTAssertEqual(LaserScannerParameter.cornerThreshold.normalized(in: profile), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LaserScannerParameter.allCases.count, 6)
        for parameter in LaserScannerParameter.allCases {
            XCTAssertTrue(parameter.range.contains(parameter.defaultValue), "\(parameter)")
        }
    }

    private func template() -> LaserProjection {
        var camera = matrix_identity_double4x4
        camera.columns.3 = SIMD4(0, 0, 2, 1)
        return LaserProjection(camera: camera, projection: LaserProjection.perspective(fovxDegrees: 90, near: 0.1, far: 50))
    }
    private func square() -> LaserLive<Laser3DBuffer> {
        let corners: [(Double, Double)] = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5), (-0.5, -0.5)]
        return FixedFrame([TestShape(id: 1, vertices: corners.map { LaserVertex(x: $0.0, y: $0.1, rgba: SIMD4(repeating: 0.1)) })])
    }
    private func line() -> LaserLive<Laser3DBuffer> {
        FixedFrame([TestShape(id: 1, vertices: [LaserVertex(x: -0.5, y: 0), LaserVertex(x: 0.5, y: 0)])])
    }

    func testTheChainRunsEndToEnd() {
        var chain = LaserReader(LaserScannerSettings.stream(from: square(), projection: template(), live: LaserLive(LaserScannerSettings())))
        let lit = chain.take(400)
        XCTAssertEqual(lit.count, 400)
        XCTAssertGreaterThan(lit.filter { $0.rgb != .zero }.count, 100)
        XCTAssertTrue(lit.contains { $0.mode == .dwell })                 // padding and corners
        var shapes = LaserScannerSettings.stream(from: square(), projection: template(), live: LaserLive(LaserScannerSettings()))
        XCTAssertEqual(shapes.read().map(\.id), [1])                       // the shape keeps its identity to the end
    }

    func testChangingTheSettingsChangesTheChain() {
        func count(_ settings: LaserScannerSettings) -> Int {
            var stream = LaserScannerSettings.stream(from: line(), projection: template(), live: LaserLive(settings))
            return stream.read().flatMap(\.points).count
        }
        let sparse = LaserScannerSettings(paddingDwell: 0, paddingBlank: 0, cornerDwell: 0, maximumStep: 0.2)
        let dense = LaserScannerSettings(paddingDwell: 0, paddingBlank: 0, cornerDwell: 0, maximumStep: 0.01)
        XCTAssertLessThan(count(sparse), count(dense))
        XCTAssertLessThan(count(LaserScannerSettings(paddingDwell: 0, paddingBlank: 0, cornerDwell: 0)), count(LaserScannerSettings(paddingDwell: 6, paddingBlank: 6, cornerDwell: 0)))
    }

    func testTheSettingsAreFollowedWhileTheChainPlays() {
        let sparse = LaserScannerSettings(paddingDwell: 0, paddingBlank: 0, cornerDwell: 0, maximumStep: 0.2)
        let dense = LaserScannerSettings(paddingDwell: 0, paddingBlank: 0, cornerDwell: 0, maximumStep: 0.01)
        var steady = LaserScannerSettings.stream(from: line(), projection: template(), live: LaserLive(sparse))
        let steadyCounts = (0..<3).map { _ in steady.read().flatMap(\.points).count }
        let live = LaserLive(sparse)
        var stream = LaserScannerSettings.stream(from: line(), projection: template(), live: live)
        let first = stream.read().flatMap(\.points).count
        live.value = dense
        let second = stream.read().flatMap(\.points).count
        live.value = sparse
        let third = stream.read().flatMap(\.points).count
        XCTAssertEqual(first, steadyCounts[0])
        XCTAssertGreaterThan(second, steadyCounts[1])      // the same stream, no rebuild
        XCTAssertEqual(third, steadyCounts[2])
    }

    func testLiveValuesAreSafeToChangeFromManyThreads() {
        let live = LaserLive(0)
        DispatchQueue.concurrentPerform(iterations: 200) { live.value = $0 }
        XCTAssertTrue((0..<200).contains(live.value))
    }
}
