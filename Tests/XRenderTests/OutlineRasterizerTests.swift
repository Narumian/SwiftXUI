import Testing
@testable import XRender

private func square(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> [OutlineRasterizer.Segment] {
    [.init(x0, y0, x1, y0), .init(x1, y0, x1, y1), .init(x1, y1, x0, y1), .init(x0, y1, x0, y0)]
}

@Test func pixelAlignedSquareIsFullyCovered() {
    let c = OutlineRasterizer.coverage(square(1, 1, 3, 3), width: 4, height: 4)
    for y in 0..<4 { for x in 0..<4 {
        let inside = (1..<3).contains(x) && (1..<3).contains(y)
        #expect(c[y * 4 + x] == (inside ? 255 : 0), "x\(x) y\(y)")
    } }
}

@Test func halfPixelOffsetGivesHalfCoverageOnTheEdge() {
    let c = OutlineRasterizer.coverage(square(0.5, 0, 2, 2), width: 3, height: 2)
    #expect(c[0] == 128)          // 0.5 px wide sliver
    #expect(c[1] == 255)
}

@Test func windingDirectionDoesNotMatter() {
    let forward = OutlineRasterizer.coverage(square(0.25, 0.25, 2.5, 1.75), width: 4, height: 3)
    let backward = OutlineRasterizer.coverage(square(0.25, 0.25, 2.5, 1.75).reversed().map {
        .init($0.x1, $0.y1, $0.x0, $0.y0)
    }, width: 4, height: 3)
    #expect(forward == backward)
}

@Test func areaIsConservedForATriangle() {
    // right triangle, legs 4 -> area 8 px^2
    let t: [OutlineRasterizer.Segment] = [.init(0, 0, 4, 0), .init(4, 0, 0, 4), .init(0, 4, 0, 0)]
    let c = OutlineRasterizer.coverage(t, width: 4, height: 4)
    let area = c.map { Float($0) / 255 }.reduce(0, +)
    #expect(abs(area - 8) < 0.05)
}
