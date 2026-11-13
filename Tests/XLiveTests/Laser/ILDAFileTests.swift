import XCTest
@testable import XLive

final class ILDAFileTests: XCTestCase {
    private func header(format: UInt8, records: Int, name: String = "T") -> [UInt8] {
        var h = Array("ILDA".utf8) + [0, 0, 0, format]
        h += Array(name.utf8) + [UInt8](repeating: 0, count: 8 - name.utf8.count)
        h += [UInt8](repeating: 0, count: 8)
        h += [UInt8(records >> 8), UInt8(records & 255), 0, 0, 0, 1, 0, 0]
        return h
    }

    func testTheDefaultPaletteIsTheStandardsAtItsLandmarks() {
        let p = ILDAFile.defaultPalette
        XCTAssertEqual(p.count, 64)
        XCTAssertEqual(p[0], [255, 0, 0]); XCTAssertEqual(p[15], [255, 240, 0]); XCTAssertEqual(p[16], [255, 255, 0])
        XCTAssertEqual(p[17], [224, 255, 0]); XCTAssertEqual(p[24], [0, 255, 0]); XCTAssertEqual(p[31], [0, 255, 255])
        XCTAssertEqual(p[32], [0, 227, 255]); XCTAssertEqual(p[40], [0, 0, 255]); XCTAssertEqual(p[47], [224, 0, 255])
        XCTAssertEqual(p[48], [255, 0, 255]); XCTAssertEqual(p[56], [255, 255, 255]); XCTAssertEqual(p[57], [255, 224, 224])
        XCTAssertEqual(p[63], [255, 32, 32])
    }

    func testIndexedFramesReadCoordinatesBlankingAndColour() throws {
        // Format 0: x, y, z, status, colour index.
        var data = header(format: 0, records: 2)
        data += [0x80, 0x00, 0x7f, 0xff, 0, 0, 0x40, 24]   // x -32768 (left), y 32767 (top), blanked, green
        data += [0x00, 0x00, 0x00, 0x00, 0, 0, 0x80, 24]   // centre, lit, last point
        data += header(format: 0, records: 0)
        let frame = try ILDAFile(data: Data(data)).frames[0]
        XCTAssertEqual(frame.points.count, 2)
        XCTAssertEqual(frame.points[0].x, -1); XCTAssertEqual(frame.points[0].y, 32767 / 32768)
        XCTAssertTrue(frame.points[0].isBlanked); XCTAssertEqual(frame.points[0].rgb, .zero)
        XCTAssertFalse(frame.points[1].isBlanked); XCTAssertEqual(frame.points[1].rgb, [0, 1, 0])
    }

    func testAFormat2PaletteReplacesTheColoursOfTheFramesAfterIt() throws {
        var data = header(format: 2, records: 2)
        data += [10, 20, 30, 255, 255, 255]
        data += header(format: 1, records: 1)
        data += [0, 0, 0, 0, 0, 0]                          // format 1: x, y, status, colour index 0
        let frame = try ILDAFile(data: Data(data)).frames[0]
        XCTAssertEqual(frame.points[0].rgb, SIMD3<Float>(10, 20, 30) / 255)
    }

    func testTrueColourFramesStoreBlueGreenRed() throws {
        var data = header(format: 5, records: 1)
        data += [0, 0, 0, 0, 0, 3, 2, 1]                    // status 0, blue 3, green 2, red 1
        let p = try ILDAFile(data: Data(data)).frames[0].points[0]
        XCTAssertEqual(p.rgb, SIMD3<Float>(1, 2, 3) / 255)
    }

    func testBadFilesAreRefused() {
        XCTAssertThrowsError(try ILDAFile(data: Data("hello".utf8)))
        var data = header(format: 0, records: 3); data += [0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertThrowsError(try ILDAFile(data: Data(data)))
    }

    func testAFrameBecomesLaserPointsAtTheGivenIntensity() throws {
        var data = header(format: 5, records: 1)
        data += [0, 0, 0, 0, 0, 255, 255, 255]
        let points = try ILDAFile(data: Data(data)).frames[0].laserPoints(intensity: 0.25)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].rgb, SIMD3<Float>(repeating: 0.25))
    }
}
