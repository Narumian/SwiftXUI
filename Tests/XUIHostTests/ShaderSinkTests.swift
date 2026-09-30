import Testing
import XRender
import XShader
import XUI
@testable import XUIHost

private struct TestShader: Shader {
    static let key: ShaderKey = "test.sceneCanvas"
    static let scope: ShaderScope = .layer

    func encode(into uniforms: inout ShaderUniforms) {
        uniforms.write(1)
    }
}

@Test @XUIActor func sceneCanvasIsolatesLayerShadersWithTheirSubviewCommands() async {
    let surface = SceneCanvas(size: RenderSize(width: 100, height: 50))
    _ = await LayoutHost(canvas: XUI.Size(width: 100, height: 50)).render(
        Color.black.frame(width: 20, height: 10, alignment: .topLeading)
            .shader(TestShader()),
        into: surface
    )

    #expect(surface.scene.shaderRegions.isEmpty)
    #expect(surface.scene.commands.count == 1)
    guard case .shaderLayer(let layer) = surface.scene.commands[0] else {
        Issue.record("Expected an isolated shader layer")
        return
    }
    #expect(layer.rect == RenderRect(x: 0, y: 0, width: 20, height: 10))
    #expect(layer.shader.key == "test.sceneCanvas")
    #expect(layer.commands.count == 1)
}
