import Testing
import XShader
@testable import XUI

private struct TestShader: Shader {
    static let key: ShaderKey = "test.tint"
    static let scope: ShaderScope = .layer
    var amount: Float

    func encode(into uniforms: inout ShaderUniforms) {
        uniforms.write(amount)
    }
}

@Test func shaderModifierExportsResolvedFrameWithoutChangingLayout() {
    let surface = RecordingCanvas()
    let result = LayoutHost(canvas: Size(width: 300, height: 200)).render(
        Color.black.frame(width: 40, height: 30, alignment: .topLeading)
            .shader(TestShader(amount: 0.75)),
        into: surface
    )

    #expect(result.shaders.count == 1)
    #expect(result.shaders[0].rect == Rect(x: 0, y: 0, width: 40, height: 30))
    #expect(result.shaders[0].shader.key == "test.tint")
    #expect(result.shaders[0].shader.uniforms.values == [0.75])
    #expect(surface.fills[0].rect == Rect(x: 0, y: 0, width: 40, height: 30))
}

@Test func shaderScopeIsRecordedForNestedViewsInPaintOrder() {
    let surface = RecordingCanvas()
    let view = VStack(spacing: 0) {
        Color.black.frame(width: 20, height: 20)
            .shader(TestShader(amount: 1))
        Color.white.frame(width: 20, height: 20)
            .shader(TestShader(amount: 2))
    }

    let result = LayoutHost(canvas: Size(width: 100, height: 100)).render(view, into: surface)
    #expect(result.shaders.map(\.shader.uniforms.values) == [[1], [2]])
}
