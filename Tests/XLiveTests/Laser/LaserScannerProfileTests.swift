import Foundation
import simd
import XCTest
@testable import XLive

final class LaserScannerProfileTests: XCTestCase {
    func testAnOutputSavedBeforeTheProfileExistedStillLoadsWithDefaults() throws {
        let id = UUID()
        let old = #"{"id":"\#(id.uuidString)","name":"Laser 01","device":"laserCube","address":"192.168.1.106","masks":{"masks":[]}}"#
        let output = try JSONDecoder().decode(LaserOutput.self, from: Data(old.utf8))
        XCTAssertEqual(output.scanner, LaserScannerProfile())
        XCTAssertEqual(output.address, "192.168.1.106")
    }

    func testAProfileRoundTripsAndMissingKeysKeepTheirDefaults() throws {
        let profile = LaserScannerProfile(paddingDwell: 5, paddingBlank: 2, screen: .cut, cornerDwell: 4, cornerThresholdDegrees: 35, maximumStep: 0.06, minimumStep: 0.01)
        XCTAssertEqual(try JSONDecoder().decode(LaserScannerProfile.self, from: JSONEncoder().encode(profile)), profile)
        let partial = try JSONDecoder().decode(LaserScannerProfile.self, from: Data(#"{"cornerDwell":2}"#.utf8))
        XCTAssertEqual(partial.cornerDwell, 2)
        XCTAssertEqual(partial.maximumStep, LaserScannerProfile().maximumStep)
    }

    func testParametersClampRoundAndReadBack() {
        var profile = LaserScannerProfile()
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

    func testTheChainRunsEndToEndAndAppliesTheOutputsMasks() {
        var camera = matrix_identity_double4x4
        camera.columns.3 = SIMD4(0, 0, 2, 1)
        let template = LaserProjection(camera: camera, projection: LaserProjection.perspective(fovxDegrees: 90, near: 0.1, far: 50))
        func frame() -> LaserFrameLooper<LaserVertex> {
            let looper = LaserFrameLooper<LaserVertex>(format: LaserStreamFormat(domain: .shapes))
            let corners: [(Double, Double)] = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5), (-0.5, -0.5)]
            looper.submit(LaserChunk(elements: corners.map { LaserVertex(x: $0.0, y: $0.1, rgba: SIMD4(repeating: 0.1)) }, shape: 1))
            return looper
        }
        var open = LaserReader(LaserScannerProfile().output(from: frame(), projection: template, masks: LaserMaskSettings()))
        let lit = open.take(400)
        XCTAssertEqual(lit.count, 400)
        XCTAssertGreaterThan(lit.elements.filter { $0.rgb != .zero }.count, 100)
        XCTAssertTrue(lit.elements.contains { $0.mode == .dwell })        // padding and corners
        XCTAssertEqual(lit.runs.first?.id, 1)
        XCTAssertFalse(lit.frameEnds.isEmpty)

        // a mask over the whole output area with no light left
        var mask = LaserMask(shape: .polygon, points: [.init(0, 0), .init(1, 0), .init(1, 1), .init(0, 1)])
        mask.dimmer = 0
        var closed = LaserReader(LaserScannerProfile().output(from: frame(), projection: template, masks: LaserMaskSettings(masks: [mask])))
        XCTAssertTrue(closed.take(400).elements.allSatisfy { $0.rgb == .zero })
    }

    func testChangingTheProfileChangesTheChain() {
        var camera = matrix_identity_double4x4
        camera.columns.3 = SIMD4(0, 0, 2, 1)
        let template = LaserProjection(camera: camera, projection: LaserProjection.perspective(fovxDegrees: 90, near: 0.1, far: 50))
        func count(_ profile: LaserScannerProfile) -> Int {
            let looper = LaserFrameLooper<LaserVertex>(format: LaserStreamFormat(domain: .shapes))
            looper.submit(LaserChunk(elements: [LaserVertex(x: -0.5, y: 0), LaserVertex(x: 0.5, y: 0)], shape: 1))
            var stream = profile.output(from: looper, projection: template, masks: LaserMaskSettings())
            return stream.read(wanting: 1).count
        }
        let sparse = LaserScannerProfile(paddingDwell: 0, paddingBlank: 0, cornerDwell: 0, maximumStep: 0.2)
        let dense = LaserScannerProfile(paddingDwell: 0, paddingBlank: 0, cornerDwell: 0, maximumStep: 0.01)
        XCTAssertLessThan(count(sparse), count(dense))
        XCTAssertLessThan(count(LaserScannerProfile(paddingDwell: 0, paddingBlank: 0, cornerDwell: 0)), count(LaserScannerProfile(paddingDwell: 6, paddingBlank: 6, cornerDwell: 0)))
    }
}
