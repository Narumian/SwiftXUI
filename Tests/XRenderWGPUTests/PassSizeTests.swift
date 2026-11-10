import Testing
import XRender
@testable import XRenderWGPU

@Test func hairlineRendersOnGPU() throws {
    let renderer = try #require(WGPURenderer(headless: ()))
    let size = RenderSize(width: 64, height: 64)
    var builder = SceneBuilder(size: size, background: RenderColor(0, 0, 0, 1))
    builder.hairline([.init(x: 8, y: 32), .init(x: 56, y: 32)], color: .white)
    let frame = SceneCompiler.compile(builder.scene, canvas: size, framebuffer: size)
    let pixels = try #require(renderer.renderToImage(frame, width: 64, height: 64))
    let lit = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 200 && pixels[$0 + 1] > 200 && pixels[$0 + 2] > 200 }
    #expect(lit.count >= 40 && lit.count <= 55)
}

@Suite struct PassSizeTests {
    /// A frame laid out for a taller window than the attachment it lands on (a resize in
    /// flight) must still give a scissor inside the attachment: 1170 against 1158 is the
    /// Metal "Set Scissor Rect Validation" assertion.
    @Test func fullHeightRectIsCutToAShorterAttachment() {
        let size = PassSize(width: 1920, height: 1158)
        let result = size.clamp(PixelRect(x: 0, y: 0, width: 1920, height: 1170))
        #expect(result.height == 1158)
        #expect(result.y + result.height <= size.height)
    }

    @Test func nilRectIsTheWholeAttachment() {
        let result = PassSize(width: 640, height: 480).clamp(nil)
        #expect(result == (0, 0, 640, 480))
    }

    @Test func rectInsideIsUntouched() {
        let result = PassSize(width: 640, height: 480).clamp(PixelRect(x: 10, y: 20, width: 100, height: 50))
        #expect(result == (10, 20, 100, 50))
    }

    @Test func originPastTheEdgeGivesAnEmptyRectAtTheEdge() {
        let size = PassSize(width: 640, height: 480)
        let result = size.clamp(PixelRect(x: 900, y: 700, width: 50, height: 50))
        #expect(result == (640, 480, 0, 0))
    }

    @Test func rectStraddlingTheEdgeIsCut() {
        let result = PassSize(width: 640, height: 480).clamp(PixelRect(x: 600, y: 450, width: 100, height: 100))
        #expect(result == (600, 450, 40, 30))
    }
}

@Suite struct StaleFrameTests {
    private func frame(_ width: UInt32, _ height: UInt32) -> CompiledFrame {
        var frame = CompiledFrame()
        frame.framebufferWidth = width
        frame.framebufferHeight = height
        return frame
    }

    /// 1938 against 1936 is the Metal "Set Scissor Rect Validation" abort: the frame was
    /// built for the window before the view resized its drawable.
    @Test func aFrameForAnotherDrawableSizeIsStale() throws {
        let renderer = try #require(WGPURenderer(headless: ()))
        renderer.drawableSizeProvider = { (1936, 1170) }
        #expect(renderer.isStale(frame(1938, 1170)))
        #expect(renderer.isStale(frame(1936, 1158)))
        #expect(!renderer.isStale(frame(1936, 1170)))
    }

    @Test func unknownSizesAreNeverStale() throws {
        let renderer = try #require(WGPURenderer(headless: ()))
        #expect(!renderer.isStale(frame(1938, 1170)))          // no provider
        renderer.drawableSizeProvider = { nil }
        #expect(!renderer.isStale(frame(1938, 1170)))          // provider cannot tell
        renderer.drawableSizeProvider = { (1936, 1170) }
        #expect(!renderer.isStale(CompiledFrame()))             // frame does not know its size
    }

    @Test func theCompilerRecordsTheFramebufferSize() {
        let compiled = SceneCompiler.compile(Scene(), canvas: RenderSize(width: 100, height: 50),
                                             framebuffer: RenderSize(width: 200.4, height: 99.6))
        #expect(compiled.framebufferWidth == 200)
        #expect(compiled.framebufferHeight == 100)
    }
}
