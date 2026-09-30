import Foundation
import Testing
@testable import XShader

@Test func appearancePrimitiveInventoryHasTwoIndependentConsumers() throws {
    let registry = try StaticShaderLibrary.registry()
    let sources = try registry.all.reduce(into: [String: String]()) { result, descriptor in
        let assembled = try StaticShaderLibrary.assembledBundledSource(for: descriptor.key)
        result[descriptor.key.rawValue] = String(assembled[assembled.range(of: "fn shade")!.lowerBound...])
    }

    func consumers(containing token: String) -> Set<String> {
        Set(sources.compactMap { name, source in
            source.contains(token) ? name : nil
        })
    }

    #expect(consumers(containing: "mask_sdf_outer_band") == ["shader.cartoon_surface", "shader.glass_surface"])
    #expect(consumers(containing: "lighting_fake_bevel") == ["shader.cartoon_surface", "shader.engraved_surface", "shader.glass_surface"])
    #expect(consumers(containing: "lighting_rim_from_uv") == ["shader.glass_surface", "shader.gold_surface", "shader.metallic_surface", "shader.neon_static_surface"])
    #expect(consumers(containing: "lighting_highlight_band") == ["shader.gold_surface", "shader.metallic_surface"])
    #expect(consumers(containing: "surface_grain") == ["shader.gold_surface", "shader.metallic_surface", "shader.paper_surface", "shader.stone_surface"])
}

@Test func appearancePrimitiveInventoryKeepsOneOffStyleLogicLocal() throws {
    let registry = try StaticShaderLibrary.registry()
    let sources = try ["shader.engraved_surface", "shader.neon_static_surface", "shader.paper_surface", "shader.stone_surface"].map { key in
        let descriptor = try #require(registry.all.first { $0.key.rawValue == key })
        let assembled = try StaticShaderLibrary.assembledBundledSource(for: descriptor.key)
        return String(assembled[assembled.range(of: "fn shade")!.lowerBound...])
    }

    // These are intentionally not promoted: no second independent consumer
    // currently establishes a stable contract for them.
    #expect(sources[0].contains("groove"))
    #expect(sources[1].contains("glow"))
    #expect(sources[2].contains("fibers"))
    #expect(sources[3].contains("speckle"))
}
