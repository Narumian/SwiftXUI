/// The deliberately small built-in static asset library. Consumers choose an
/// asset key and receive its assembled WGSL without depending on individual
/// asset implementation types.
public enum StaticShaderLibrary {
    public static var descriptors: [ShaderAssetDescriptor] {
        [
            GradientSurfaceAsset.descriptor,
            CartoonSurfaceAsset.descriptor,
            MetallicSurfaceAsset.descriptor,
            GoldSurfaceAsset.descriptor,
            PaperSurfaceAsset.descriptor,
            GlassSurfaceAsset.descriptor,
            StoneSurfaceAsset.descriptor,
            EngravedSurfaceAsset.descriptor,
            NeonStaticSurfaceAsset.descriptor,
        ]
    }

    public static func registry() throws -> ShaderAssetRegistry {
        try ShaderAssetRegistry(descriptors)
    }

    public static func assembledBundledSource(for key: ShaderAssetKey) throws -> String {
        switch key {
        case GradientSurfaceAsset.key:
            return try GradientSurfaceAsset.assembledBundledSource()
        case CartoonSurfaceAsset.key:
            return try CartoonSurfaceAsset.assembledBundledSource()
        case MetallicSurfaceAsset.key:
            return try MetallicSurfaceAsset.assembledBundledSource()
        case GoldSurfaceAsset.key:
            return try GoldSurfaceAsset.assembledBundledSource()
        case PaperSurfaceAsset.key:
            return try PaperSurfaceAsset.assembledBundledSource()
        case GlassSurfaceAsset.key:
            return try GlassSurfaceAsset.assembledBundledSource()
        case StoneSurfaceAsset.key:
            return try StoneSurfaceAsset.assembledBundledSource()
        case EngravedSurfaceAsset.key:
            return try EngravedSurfaceAsset.assembledBundledSource()
        case NeonStaticSurfaceAsset.key:
            return try NeonStaticSurfaceAsset.assembledBundledSource()
        default:
            throw Error.unknownAsset(key)
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable { case unknownAsset(ShaderAssetKey) }
}
