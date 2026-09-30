import Testing
@testable import XShader

@Test func staticShaderLibraryAssetsStayWithinTheStaticShaderContract() throws {
    let registry = try StaticShaderLibrary.registry()
    #expect(registry.all.count == 9)

    for descriptor in registry.all {
        // Metadata and parameter descriptors are authored inputs, so validate them
        // independently of registry construction as a regression guard.
        try descriptor.validate()
        #expect((3...8).contains(descriptor.parameters.count))

        let payload = try ShaderAssetUniformPayload(
            descriptor: descriptor,
            values: ShaderParameterValues(descriptor: descriptor),
            outputSize: (320, 180),
            contentAspect: 16.0 / 9.0
        )
        #expect(payload.data.count == 80)
        #expect(payload.floats.count == 20)

        let source = try StaticShaderLibrary.assembledBundledSource(for: descriptor.key)
        #expect(source.contains("@group(0) @binding(0) var input_texture"))
        #expect(source.contains("@group(0) @binding(1) var input_sampler"))
        #expect(source.contains("@group(0) @binding(2) var<uniform> params"))
        #expect(source.contains("fn vs_main"))
        #expect(source.contains("fn fs_main"))
        #expect(source.contains("fn shade"))
        #expect(!source.contains("shader-include:"))

        // Foundation comments document the absence of time, so inspect WGSL tokens
        // after removing comments to guard actual identifiers and declarations.
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
        let identifiers = Set(code.split { character in
            !(character.isNumber || character == "_" || character.isLetter)
        }.map(String.init))
        for dynamicIdentifier in ["time", "delta", "progress", "animation_progress", "animationProgress", "elapsed"] {
            #expect(!identifiers.contains(dynamicIdentifier))
        }
    }
}
