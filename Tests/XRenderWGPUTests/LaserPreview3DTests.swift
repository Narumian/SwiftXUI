import Foundation
import Testing
import simd
import XLive
import XUI
import XUIHost
import XRender
@testable import XRenderWGPU

@Test func laserPreviewReadsOriginalLaser3DBufferPayloadAndShapeRanges() throws {
    let ranges: [UInt32] = [1, 2, 1, 2, 0, 3]
    let vertices: [Float] = [
        -1, 0, 0, 1, 1, 1, 1, 1,
        0, 0, 0, 1, 1, 1, 1, 1,
        1, 0, 0, 1, 1, 1, 1, 1,
    ]
    let modes: [UInt16] = [0, 0, 0]
    var source = Laser3DBuffer()
    try ranges.withUnsafeBufferPointer { r in
        try vertices.withUnsafeBufferPointer { v in
            try modes.withUnsafeBufferPointer { m in try source.replaceContents(shapes: r, values: v, modes: m) }
        }
    }
    #expect(source.vertexCount == 3)
    #expect(source.vertexValues == vertices)
    #expect(source.vertexModes == modes)
    #expect(source.shapes.map { Int($0.start)..<(Int($0.start) + Int($0.count)) } == [2..<3, 0..<3])
}

@Test @XUIActor func laserPreviewProjectsAndSeparatesPathsOnGPU() async throws {
    var source = Laser3DBuffer()
    try source.beginShape(id: 1)
    try source.appendVertex(LaserVertex(x: -0.8, y: 0.5, rgba: SIMD4(1, 0, 0, 1)))
    try source.appendVertex(LaserVertex(x: -0.2, y: 0.5, rgba: SIMD4(1, 0, 0, 1)))
    try source.beginShape(id: 2)
    try source.appendVertex(LaserVertex(x: 0.2, y: -0.5, rgba: SIMD4(0, 1, 0, 1)))
    try source.appendVertex(LaserVertex(x: 0.8, y: -0.5, rgba: SIMD4(0, 1, 0, 1)))
    let size = RenderSize(width: 64, height: 64)
    let host = XUIHost(size: size, background: RenderColor(0, 0, 0, 1))
    let scene = await host.render(LaserPreview3D(source, projection: LaserProjection(projection: matrix_identity_double4x4))).scene
    let frame = SceneCompiler.compile(scene, canvas: size, framebuffer: size)
    let renderer = try #require(WGPURenderer(headless: ()))
    let pixels = try #require(renderer.renderToImage(frame, width: 64, height: 64))
    func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let i = (y * 64 + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }
    let colors = stride(from: 0, to: pixels.count, by: 4).map { (pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) }
    #expect(colors.contains { $0.0 > 200 && $0.1 < 20 })
    #expect(colors.contains { $0.1 > 200 && $0.0 < 20 })
    let center = pixel(32, 32)
    #expect(center.0 < 20 && center.1 < 20 && center.2 < 20)
    guard case .laserPreview(let command) = try #require(scene.commands.first) else { Issue.record("Expected dedicated laser preview command"); return }
    let clipped = Scene(background: RenderColor(0, 0, 0, 1), commands: [
        .laserPreview(LaserPreviewCommand(vertices: command.vertices, modes: command.modes, shapes: command.shapes,
            matrix: command.matrix, rect: command.rect, clip: RenderRect(x: 0, y: 0, width: 32, height: 64)))
    ], authoringCanvas: size)
    let clippedFrame = SceneCompiler.compile(clipped, canvas: size, framebuffer: size)
    let clippedPixels = try #require(renderer.renderToImage(clippedFrame, width: 64, height: 64))
    let clippedColors = stride(from: 0, to: clippedPixels.count, by: 4).map { (clippedPixels[$0], clippedPixels[$0 + 1]) }
    #expect(clippedColors.contains { $0.0 > 200 })
    #expect(!clippedColors.contains { $0.1 > 200 })
}

@Test @XUIActor func laserPreviewAppliesProjectionAndBlankingOnGPU() async throws {
    var source = Laser3DBuffer()
    try source.beginShape(id: 1)
    try source.appendVertex(LaserVertex(x: -0.8, y: 0))
    try source.appendVertex(LaserVertex(x: -0.4, y: 0))
    try source.appendVertex(LaserVertex(x: 0, y: 0, mode: .blank))
    try source.appendVertex(LaserVertex(x: 0.8, y: 0))
    var camera = matrix_identity_double4x4
    camera.columns.3.x = 0.4
    let size = RenderSize(width: 64, height: 64)
    let host = XUIHost(size: size, background: RenderColor(0, 0, 0, 1))
    let scene = await host.render(LaserPreview3D(source, projection: LaserProjection(camera: camera, projection: matrix_identity_double4x4))).scene
    let frame = SceneCompiler.compile(scene, canvas: size, framebuffer: size)
    let renderer = try #require(WGPURenderer(headless: ()))
    let pixels = try #require(renderer.renderToImage(frame, width: 64, height: 64))
    func bright(_ x: Int) -> Bool {
        (30...33).contains { y in pixels[(y * 64 + x) * 4] > 200 }
    }
    #expect(bright(24))
    #expect(!bright(8))
    #expect(!bright(48))
}

@Test @XUIActor func laserPreviewClipsCrossingNearPlaneOnGPU() async throws {
    var source = Laser3DBuffer()
    try source.beginShape(id: 1)
    try source.appendVertex(LaserVertex(x: -0.8, y: 0, z: -2))
    try source.appendVertex(LaserVertex(x: 0.8, y: 0, z: 0))
    let size = RenderSize(width: 64, height: 64)
    let host = XUIHost(size: size, background: RenderColor(0, 0, 0, 1))
    let scene = await host.render(LaserPreview3D(source, projection: LaserProjection(projection: matrix_identity_double4x4))).scene
    let frame = SceneCompiler.compile(scene, canvas: size, framebuffer: size)
    let renderer = try #require(WGPURenderer(headless: ()))
    let pixels = try #require(renderer.renderToImage(frame, width: 64, height: 64))
    func bright(_ x: Int) -> Bool {
        (30...33).contains { y in pixels[(y * 64 + x) * 4] > 200 }
    }
    #expect(!bright(20))
    #expect(bright(40))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LASER_PREVIEW_BENCH"] != nil))
@XUIActor func laserPreviewGPUBenchmark() async throws {
    let size = RenderSize(width: 64, height: 64)
    let renderer = try #require(WGPURenderer(headless: ()))
    func timing(_ scene: Scene, _ canvas: RenderSize) throws -> Double {
        let warm = SceneCompiler.compile(scene, canvas: canvas, framebuffer: canvas)
        _ = try #require(renderer.renderToImage(warm, width: 64, height: 64))
        let clock = ContinuousClock(), start = clock.now
        for _ in 0..<20 {
            let frame = SceneCompiler.compile(scene, canvas: canvas, framebuffer: canvas)
            _ = try #require(renderer.renderToImage(frame, width: 64, height: 64))
        }
        let d = start.duration(to: clock.now).components
        return (Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15) / 20
    }
    for count in [120, 1_200, 6_000] {
        var source = Laser3DBuffer()
        try source.beginShape(id: 1)
        for i in 0..<count {
            let a = Float(i) * 2 * .pi / Float(count - 1)
            try source.appendVertex(LaserVertex(x: cos(a) * 0.8, y: sin(a) * 0.8))
        }
        let host = XUIHost(size: size, background: RenderColor(0, 0, 0, 1))
        let viewScene = await host.render(LaserPreview3D(source, projection: LaserProjection(projection: matrix_identity_double4x4))).scene
        guard case .laserPreview(let view) = try #require(viewScene.commands.first) else { Issue.record("Expected dedicated laser preview command"); return }
        var gpuScene = Scene(background: RenderColor(0, 0, 0, 1))
        var lines = SceneBuilder(size: size, background: RenderColor(0, 0, 0, 1))
        for i in 0..<12 {
            let x = Float(i % 4) * 16, y = Float(i / 4) * 16
            gpuScene.append(.laserPreview(LaserPreviewCommand(vertices: view.vertices, modes: view.modes, shapes: view.shapes,
                matrix: view.matrix, rect: RenderRect(x: x, y: y, width: 16, height: 16))))
            lines.hairline((0..<count).map { j in
                let a = Float(j) * 2 * .pi / Float(count - 1)
                return RenderPoint(x: x + 8 + cos(a) * 6, y: y + 8 + sin(a) * 6)
            }, color: .white)
        }
        let cpuMS = try timing(lines.scene, size), gpuMS = try timing(gpuScene, size)
        print("BENCH \(count) pts × 12 at 64x64, compile + draw: CPU lines \(cpuMS) ms, laser shader \(gpuMS) ms")
    }
}
