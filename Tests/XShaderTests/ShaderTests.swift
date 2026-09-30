import Foundation
import Testing
@testable import XShader

private struct TestShader: Shader {
    static let key: ShaderKey = "test.pulse"
    static let scope: ShaderScope = .material

    var amount: Float

    func encode(into uniforms: inout ShaderUniforms) {
        uniforms.write(amount)
        uniforms.write(SIMD2<Float>(1, 2))
    }
}

@Test func shaderErasesItsIdentityScopeAndUniforms() {
    let shader = AnyShader(TestShader(amount: 0.75))
    #expect(shader.key == "test.pulse")
    #expect(shader.scope == .material)
    #expect(shader.uniforms.values == [0.75, 1, 2])
}

@Test func shaderKeyRoundTripsCodable() throws {
    let key: ShaderKey = "rigged.cellGlow"
    let data = try JSONEncoder().encode(key)
    #expect(try JSONDecoder().decode(ShaderKey.self, from: data) == key)
}

@Test func builtInShaderLibraryUsesStableKeysAndPackedArguments() {
    let glow = AnyShader(ShaderLibrary.cellGlow(color: SIMD3(1, 0.5, 0), intensity: 0.75))
    #expect(glow.key == "swiftx.cellGlow")
    #expect(glow.scope == .layer)
    #expect(glow.uniforms.values == [1, 0.5, 0, 0.75])

    let glass = AnyShader(ShaderLibrary.glass(tint: SIMD3(0.7, 0.88, 1), intensity: 0.3))
    #expect(glass.key == "swiftx.glass")
    #expect(glass.uniforms.values == [0.7, 0.88, 1, 0.3])
}
