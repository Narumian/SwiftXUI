import Testing
import XShader
@testable import XRender

private struct TestShader: Shader {
    static let key: ShaderKey = "test.region"
    static let scope: ShaderScope = .layer

    var progress: Float

    func encode(into uniforms: inout ShaderUniforms) {
        uniforms.write(progress)
    }
}

@Test func shaderRegionSurvivesSceneBuildAndMapsToFramebuffer() {
    var builder = SceneBuilder(size: RenderSize(width: 100, height: 50))
    builder.shader(AnyShader(TestShader(progress: 0.5)),
                   in: RenderRect(x: 10, y: 5, width: 20, height: 10))

    let frame = SceneCompiler.compile(
        builder.scene,
        canvas: RenderSize(width: 100, height: 50),
        framebuffer: RenderSize(width: 200, height: 100)
    )

    #expect(frame.shaderRegions.count == 1)
    #expect(frame.shaderRegions[0].rect == PixelRect(x: 20, y: 10, width: 40, height: 20))
    #expect(frame.shaderRegions[0].shader.key == "test.region")
    #expect(frame.shaderRegions[0].shader.uniforms.values == [0.5])
}

@Test func shaderLayerCompilesItsSubtreeAtTheOriginalPaintPosition() {
    var builder = SceneBuilder(size: RenderSize(width: 100, height: 50))
    builder.rect(RenderRect(x: 0, y: 0, width: 100, height: 50), color: .black)
    builder.shaderLayer(
        AnyShader(TestShader(progress: 0.5)), in: RenderRect(x: 10, y: 5, width: 20, height: 10),
        commands: [.shape(ShapeCommand(geometry: .rect(RenderRect(x: 10, y: 5, width: 20, height: 10), corner: 0), color: .white))]
    )
    builder.rect(RenderRect(x: 40, y: 0, width: 10, height: 10), color: .white)

    let frame = SceneCompiler.compile(
        builder.scene, canvas: RenderSize(width: 100, height: 50),
        framebuffer: RenderSize(width: 200, height: 100)
    )

    #expect(frame.draws.count == 3)
    #expect(frame.draws[1] == .shaderLayer(index: 0))
    #expect(frame.shaderLayers.count == 1)
    #expect(frame.shaderLayers[0].rect == PixelRect(x: 20, y: 10, width: 40, height: 20))
    #expect(frame.shaderLayers[0].frame.draws.count == 1)
}
