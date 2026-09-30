import Testing
import XShader

@Test func gradientSurfacePNGIsNonEmptyAndValid() throws {
    let png = try GradientSurfacePNGRenderer.renderPNG(width: 16, height: 9)
    #expect(png.count > 100)
    #expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
}

@Test func gradientSurfacePNGIsDeterministic() throws {
    let first = try GradientSurfacePNGRenderer.renderPNG(width: 11, height: 7)
    let second = try GradientSurfacePNGRenderer.renderPNG(width: 11, height: 7)
    #expect(first == second)
}

@Test func gradientSurfacePNGDescriptorDefaultsMatchConvenienceDefaults() throws {
    let descriptor = GradientSurfaceAsset.descriptor
    let values = ShaderParameterValues(descriptor: descriptor)
    let explicit = try GradientSurfacePNGRenderer.renderPNG(
        descriptor: descriptor, values: values, width: 4, height: 3)
    let convenience = try GradientSurfacePNGRenderer.renderPNG(width: 4, height: 3)
    #expect(explicit == convenience)
}
