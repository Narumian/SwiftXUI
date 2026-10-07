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

@Test func surfaceShadersPackFourUniformsUnderStableKeys() {
    let foil = ShaderLibrary.foil(phase: 0.25, density: 3, saturation: 0.5, strength: 0.8).erased()
    #expect(foil.key == ShaderLibrary.foilKey)
    #expect(foil.scope == .layer)
    #expect(foil.uniforms.values == [0.25, 3, 0.5, 0.8])

    let lenticular = ShaderLibrary.lenticular(tilt: -0.5, stripes: 10, depth: 2, strength: 1).erased()
    #expect(lenticular.key == ShaderLibrary.lenticularKey)
    #expect(lenticular.uniforms.values == [-0.5, 10, 2, 1])

    let warp = ShaderLibrary.warp(phase: 0.5, frequency: 7, strength: 0.6, amplitude: 0.25).erased()
    #expect(warp.key == ShaderLibrary.warpKey)
    #expect(warp.uniforms.values == [0.5, 7, 0.25, 0.6])
}
