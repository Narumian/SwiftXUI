import CWGPU
import XRender
import XShader

/// Cross-platform WebGPU renderer. Platform code supplies only the surface.
/// Everything submitted here is backend-neutral geometry compiled from a `Scene`.
public final class WGPURenderer: XRenderer {
    private static let maxShaderRegions = 16
    // resolution/time/intensity/effectCount + implicit WGSL alignment gap +
    // 16 Effect structs (rect, params, kind + trailing padding). The array's
    // 16-byte alignment places it at float offset 8.
    private static let postUniformFloatCount = 8 + maxShaderRegions * 12
    let instance: WGPUInstance
    /// nil for a headless renderer (`init(headless:)`), which only draws to
    /// offscreen textures via `renderToImage`.
    private let surface: WGPUSurface?
    private let adapter: WGPUAdapter
    let device: WGPUDevice
    let queue: WGPUQueue
    private let shader: WGPUShaderModule
    private let pipeline: WGPURenderPipeline

    let surfaceFormat = WGPUTextureFormat_BGRA8Unorm
    var configuredWidth: UInt32 = 0
    var configuredHeight: UInt32 = 0
    private var vertexBuffer: WGPUBuffer?
    private var vertexBufferCapacity = 0

    // Sprite path. Created lazily on the first `registerTexture` so a shape-only
    // frame renders byte-for-byte as it did before this pipeline existed.
    private var spriteShader: WGPUShaderModule?
    private var spritePipeline: WGPURenderPipeline?
    private var spriteBindGroupLayout: WGPUBindGroupLayout?
    private var spriteSampler: WGPUSampler?
    private var spriteVertexBuffer: WGPUBuffer?
    private var spriteVertexBufferCapacity = 0
    // SDF font vertices have their own compact pipeline, so texture sprites
    // do not pay for outline attributes they cannot use.
    private var fontShader: WGPUShaderModule?
    private var fontPipeline: WGPURenderPipeline?
    private var fontVertexBuffer: WGPUBuffer?
    private var fontVertexBufferCapacity = 0

    private struct TextureRecord {
        var texture: WGPUTexture
        var view: WGPUTextureView
        var bindGroup: WGPUBindGroup
    }
    private var textures: [UInt32: TextureRecord] = [:]

    /// Fullscreen post pass (dither + VHS). 0 disables it; the scene renders
    /// straight to the surface.
    public var postIntensity: Float = 0.0
    private var postShader: WGPUShaderModule?
    private var postPipeline: WGPURenderPipeline?
    private var postBindGroupLayout: WGPUBindGroupLayout?
    private var postSampler: WGPUSampler?
    private var postUniformBuffer: WGPUBuffer?
    private var sceneTexture: WGPUTexture?
    private var sceneView: WGPUTextureView?
    private var postBindGroup: WGPUBindGroup?
    private var sceneTextureWidth: UInt32 = 0
    private var sceneTextureHeight: UInt32 = 0

    struct LayerTarget {
        var texture: WGPUTexture
        var view: WGPUTextureView
    }
    struct GeometryBuffers {
        var shapes: WGPUBuffer?
        var sprites: WGPUBuffer?
        var fonts: WGPUBuffer?
    }
    /// One transparent render target per nesting depth. Reusing them across
    /// frames avoids allocation churn while still allowing nested view layers.
    private var shaderLayerTargets: [LayerTarget] = []
    /// Layer composites need independent uniforms/bind groups because several
    /// passes can be encoded before the command buffer is submitted.
    var transientPostBindGroups: [WGPUBindGroup] = []
    var transientPostUniformBuffers: [WGPUBuffer] = []
    /// Layer geometry cannot reuse the root frame's buffers: all passes run
    /// after command-buffer submission, so a later CPU upload would otherwise
    /// overwrite vertices referenced by an earlier encoded pass.
    private var transientGeometryBuffers: [WGPUBuffer] = []

    var x3dShaderSources: [ShaderKey: String] = [:]
    var x3dModules: [ShaderKey: WGPUShaderModule] = [:]
    var x3dPipelines: [String: WGPURenderPipeline] = [:]
    var x3dComputePipelines: [String: WGPUComputePipeline] = [:]
    var x3dGroupLayouts: [String: WGPUBindGroupLayout] = [:]
    var x3dPipelineLayouts: [String: WGPUPipelineLayout] = [:]
    var x3dResources: [X3DResourceID: X3DResourceRecord] = [:]
    var x3dSampler: WGPUSampler?
    var x3dFailures: Set<String> = []
    var x3dDepthTargets: [String: (texture: WGPUTexture, view: WGPUTextureView)] = [:]
    var x3dPlaneTargets: [(texture: WGPUTexture, view: WGPUTextureView, width: UInt32, height: UInt32)] = []
    var x3dFrameIndex: UInt32 = 0
    var x3dLastTime: Float?
    var x3dTime: Float = 0
    var x3dDeltaTime: Float = 0

    /// The closure is the sole vendor seam. It receives the WebGPU instance
    /// and creates a surface from the vendor window/layer handle.
    public convenience init?(makeSurface: (WGPUInstance) -> WGPUSurface?) {
        guard let instance = wgpuCreateInstance(nil) else { return nil }
        guard let surface = makeSurface(instance) else {
            wgpuInstanceRelease(instance)
            return nil
        }
        self.init(ownedInstance: instance, surface: surface)
    }

    /// C-ABI friendly ownership handoff used by thin vendor shells.
    public convenience init?(
        ownedInstancePointer: UnsafeMutableRawPointer,
        surfacePointer: UnsafeMutableRawPointer
    ) {
        self.init(
            ownedInstance: OpaquePointer(ownedInstancePointer),
            surface: OpaquePointer(surfacePointer)
        )
    }

    /// A renderer with no window: it draws `CompiledFrame`s into offscreen
    /// textures and reads them back (`renderToImage`). Same pipelines, same
    /// WGSL as the on-screen renderer, so previews match what ships.
    public convenience init?(headless: Void) {
        guard let instance = wgpuCreateInstance(nil) else { return nil }
        self.init(ownedInstance: instance, surface: nil)
    }

    private init?(ownedInstance instance: WGPUInstance, surface: WGPUSurface?) {
        installWGPULoggingOnce()
        func releaseSurface() { if let surface { wgpuSurfaceRelease(surface) } }
        guard let adapter = requestAdapterSync(instance: instance, surface: surface) else {
            releaseSurface(); wgpuInstanceRelease(instance); return nil
        }
        guard let device = requestDeviceSync(instance: instance, adapter: adapter) else {
            wgpuAdapterRelease(adapter); releaseSurface(); wgpuInstanceRelease(instance); return nil
        }
        guard let queue = wgpuDeviceGetQueue(device) else {
            wgpuDeviceRelease(device); wgpuAdapterRelease(adapter)
            releaseSurface(); wgpuInstanceRelease(instance); return nil
        }
        guard let shader = Self.makeShaderModule(device: device, wgsl: drawListWGSL),
              let pipeline = Self.makePipeline(device: device, shader: shader, format: surfaceFormat) else {
            wgpuQueueRelease(queue); wgpuDeviceRelease(device); wgpuAdapterRelease(adapter)
            releaseSurface(); wgpuInstanceRelease(instance); return nil
        }

        self.instance = instance
        self.surface = surface
        self.adapter = adapter
        self.device = device
        self.queue = queue
        self.shader = shader
        self.pipeline = pipeline
    }

    deinit {
        for record in textures.values {
            wgpuBindGroupRelease(record.bindGroup)
            wgpuTextureViewRelease(record.view)
            wgpuTextureRelease(record.texture)
        }
        if let spriteVertexBuffer { wgpuBufferRelease(spriteVertexBuffer) }
        if let fontVertexBuffer { wgpuBufferRelease(fontVertexBuffer) }
        if let fontPipeline { wgpuRenderPipelineRelease(fontPipeline) }
        if let fontShader { wgpuShaderModuleRelease(fontShader) }
        if let spritePipeline { wgpuRenderPipelineRelease(spritePipeline) }
        if let spriteBindGroupLayout { wgpuBindGroupLayoutRelease(spriteBindGroupLayout) }
        if let spriteSampler { wgpuSamplerRelease(spriteSampler) }
        if let spriteShader { wgpuShaderModuleRelease(spriteShader) }
        if let postBindGroup { wgpuBindGroupRelease(postBindGroup) }
        if let sceneView { wgpuTextureViewRelease(sceneView) }
        if let sceneTexture { wgpuTextureRelease(sceneTexture) }
        if let postUniformBuffer { wgpuBufferRelease(postUniformBuffer) }
        if let postPipeline { wgpuRenderPipelineRelease(postPipeline) }
        if let postBindGroupLayout { wgpuBindGroupLayoutRelease(postBindGroupLayout) }
        if let postSampler { wgpuSamplerRelease(postSampler) }
        if let postShader { wgpuShaderModuleRelease(postShader) }
        releaseShaderLayerTargets()
        releaseTransientPostResources()
        releaseTransientGeometryBuffers()
        releaseX3DResources()
        if let vertexBuffer { wgpuBufferRelease(vertexBuffer) }
        wgpuRenderPipelineRelease(pipeline)
        wgpuShaderModuleRelease(shader)
        wgpuQueueRelease(queue)
        wgpuDeviceRelease(device)
        wgpuAdapterRelease(adapter)
        if let surface { wgpuSurfaceRelease(surface) }
        wgpuInstanceRelease(instance)
    }

    public func configure(width: UInt32, height: UInt32) {
        guard width > 0, height > 0 else { return }
        guard width != configuredWidth || height != configuredHeight else { return }
        guard let surface else {
            configuredWidth = width
            configuredHeight = height
            releaseShaderLayerTargets()
            return
        }

        var config = WGPUSurfaceConfiguration()
        config.device = device
        config.format = surfaceFormat
        config.usage = WGPUTextureUsage_RenderAttachment
        config.width = width
        config.height = height
        config.alphaMode = WGPUCompositeAlphaMode_Opaque
        config.presentMode = WGPUPresentMode_Fifo
        wgpuSurfaceConfigure(surface, &config)
        configuredWidth = width
        configuredHeight = height
        releaseShaderLayerTargets()
    }

    /// Acquire the current surface drawable, hand its view + a fresh encoder to
    /// `encode`, submit, and **always present**. Once `wgpuSurfaceGetCurrentTexture`
    /// hands back a drawable it MUST be presented — a dropped drawable wedges the
    /// next `wgpuSurfaceGetCurrentTexture` in a wait that survives SIGKILL on
    /// macOS. So even a failed encode (`wgpuCommandEncoderFinish` → nil from a
    /// validation error) still presents, showing one bad frame instead of hanging.
    private func withDrawable(_ encode: (WGPUTextureView, WGPUCommandEncoder) -> Void) {
        guard let surface, configuredWidth > 0, configuredHeight > 0 else { return }

        var surfaceTexture = WGPUSurfaceTexture()
        wgpuSurfaceGetCurrentTexture(surface, &surfaceTexture)
        switch surfaceTexture.status {
        case WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal,
             WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal:
            break
        case WGPUSurfaceGetCurrentTextureStatus_Timeout,
             WGPUSurfaceGetCurrentTextureStatus_Outdated:
            if let texture = surfaceTexture.texture { wgpuTextureRelease(texture) }
            return
        default:
            if let texture = surfaceTexture.texture { wgpuTextureRelease(texture) }
            let width = configuredWidth, height = configuredHeight
            configuredWidth = 0; configuredHeight = 0
            configure(width: width, height: height)
            return
        }
        guard let texture = surfaceTexture.texture else { return }

        var didPresent = false
        func present() {
            guard !didPresent else { return }
            didPresent = true
            _ = wgpuSurfacePresent(surface)
            _ = wgpuDevicePoll(device, 0, nil)
        }
        defer { present(); wgpuTextureRelease(texture) }

        guard let view = wgpuTextureCreateView(texture, nil) else { return }
        defer { wgpuTextureViewRelease(view) }
        guard let encoder = wgpuDeviceCreateCommandEncoder(device, nil) else { return }
        defer { wgpuCommandEncoderRelease(encoder) }

        encode(view, encoder)

        if let commandBuffer = wgpuCommandEncoderFinish(encoder, nil) {
            // The imported C signature is `UnsafePointer<WGPUCommandBuffer?>?`:
            // pass an optional command-buffer slot, not a pointer to the
            // non-optional OpaquePointer returned by `Finish`.
            var submitted: WGPUCommandBuffer? = commandBuffer
            withUnsafePointer(to: &submitted) {
                wgpuQueueSubmit(queue, 1, $0)
            }
            wgpuCommandBufferRelease(commandBuffer)
        } else if !loggedFinishFailure {
            loggedFinishFailure = true
            rendererLog("[WGPU] command encoder finish failed — presenting an unrendered drawable")
        }
        present()
    }
    private var loggedFinishFailure = false

    // MARK: - Scene path (DrawCommand)

    /// The full mip chain of a premultiplied RGBA8 image: level 0 is the image, each
    /// next level a 2×2 box average (edges clamp for odd sizes), down to 1×1.
    ///
    /// Runs for every texture at launch, so it is written with raw buffers and
    /// while-loops and pinned to `-O`: the generic `Range` iteration a plain
    /// `for` compiles to under Debug made startup take minutes.
    @_optimize(speed)
    public static func mipChain(rgba: [UInt8], width: Int, height: Int) -> [(rgba: [UInt8], width: Int, height: Int)] {
        var levels = [(rgba: rgba, width: width, height: height)]
        var srcW = width, srcH = height
        var src = rgba
        while srcW > 1 || srcH > 1 {
            let w = max(1, srcW / 2), h = max(1, srcH / 2)
            let lastW = srcW, lastH = srcH
            var next = [UInt8](repeating: 0, count: w * h * 4)
            src.withUnsafeBufferPointer { s in
                next.withUnsafeMutableBufferPointer { d in
                    boxDownsample(s.baseAddress!, srcWidth: lastW, srcHeight: lastH, into: d.baseAddress!, width: w, height: h)
                }
            }
            levels.append((next, w, h))
            src = next
            srcW = w; srcH = h
        }
        return levels
    }

    /// One 2×2 box-filter step. It lives in its own function, not in the
    /// closures of `mipChain`: `@_optimize(speed)` does not reach a closure's
    /// body, so a loop written inside one still runs unoptimised in Debug.
    @_optimize(speed)
    private static func boxDownsample(
        _ s: UnsafePointer<UInt8>, srcWidth lastW: Int, srcHeight lastH: Int,
        into d: UnsafeMutablePointer<UInt8>, width w: Int, height h: Int
    ) {
        var y = 0
        while y < h {
            let y0 = min(2 * y, lastH - 1), y1 = min(2 * y + 1, lastH - 1)
            var x = 0
            while x < w {
                let x0 = min(2 * x, lastW - 1), x1 = min(2 * x + 1, lastW - 1)
                let a = (y0 * lastW + x0) * 4, b = (y0 * lastW + x1) * 4
                let c = (y1 * lastW + x0) * 4, e = (y1 * lastW + x1) * 4
                let o = (y * w + x) * 4
                var ch = 0
                while ch < 4 {
                    let sum = Int(s[a + ch]) + Int(s[b + ch]) + Int(s[c + ch]) + Int(s[e + ch])
                    d[o + ch] = UInt8((sum + 2) / 4)
                    ch += 1
                }
                x += 1
            }
            y += 1
        }
    }

    /// Upload an RGBA8 image (premultiplied alpha, tightly packed, top row
    /// first) under `id`. Replaces any existing texture with that id.
    ///
    /// With `mipmaps` the whole chain down to 1×1 is built (2×2 box filter, on the
    /// premultiplied values) and uploaded, so art authored large and drawn small
    /// doesn't shimmer. Leave it off for a texture that `updateTexture` rewrites
    /// (the glyph atlas): only the base level would change.
    public func registerTexture(_ id: TextureID, rgba: [UInt8], width: Int, height: Int, mipmaps: Bool = false) {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return }
        let levels = mipmaps ? Self.mipChain(rgba: rgba, width: width, height: height) : [(rgba: rgba, width: width, height: height)]
        registerTexture(id, levels: levels)
    }

    /// Upload an image whose mip chain was already built (`mipChain`), level 0
    /// first. Building the chain is pure CPU work, so a loader can do it on
    /// several threads and hand the results to this (main-thread) call.
    public func registerTexture(_ id: TextureID, levels: [(rgba: [UInt8], width: Int, height: Int)]) {
        guard let base = levels.first, base.width > 0, base.height > 0,
              base.rgba.count >= base.width * base.height * 4 else { return }
        let width = base.width, height = base.height
        guard ensureSpriteResources() else { return }

        var descriptor = WGPUTextureDescriptor()
        descriptor.usage = WGPUTextureUsage_TextureBinding | WGPUTextureUsage_CopyDst
        descriptor.dimension = WGPUTextureDimension_2D
        descriptor.size = WGPUExtent3D(width: UInt32(width), height: UInt32(height), depthOrArrayLayers: 1)
        descriptor.format = WGPUTextureFormat_RGBA8Unorm
        descriptor.mipLevelCount = UInt32(levels.count)
        descriptor.sampleCount = 1
        guard let texture = wgpuDeviceCreateTexture(device, &descriptor),
              let view = wgpuTextureCreateView(texture, nil) else {
            return
        }

        for (level, image) in levels.enumerated() {
            var destination = WGPUTexelCopyTextureInfo()
            destination.texture = texture
            destination.mipLevel = UInt32(level)
            destination.aspect = WGPUTextureAspect_All
            var layout = WGPUTexelCopyBufferLayout()
            layout.bytesPerRow = UInt32(image.width * 4)
            layout.rowsPerImage = UInt32(image.height)
            var extent = WGPUExtent3D(width: UInt32(image.width), height: UInt32(image.height), depthOrArrayLayers: 1)
            image.rgba.withUnsafeBytes { bytes in
                wgpuQueueWriteTexture(queue, &destination, bytes.baseAddress, bytes.count, &layout, &extent)
            }
        }

        var entries = [WGPUBindGroupEntry(), WGPUBindGroupEntry()]
        entries[0].binding = 0
        entries[0].textureView = view
        entries[1].binding = 1
        entries[1].sampler = spriteSampler
        let bindGroup = entries.withUnsafeBufferPointer { pointer -> WGPUBindGroup? in
            var descriptor = WGPUBindGroupDescriptor()
            descriptor.layout = spriteBindGroupLayout
            descriptor.entryCount = pointer.count
            descriptor.entries = pointer.baseAddress
            return wgpuDeviceCreateBindGroup(device, &descriptor)
        }
        guard let bindGroup else {
            wgpuTextureViewRelease(view); wgpuTextureRelease(texture); return
        }

        if let old = textures[id.rawValue] {
            wgpuBindGroupRelease(old.bindGroup)
            wgpuTextureViewRelease(old.view)
            wgpuTextureRelease(old.texture)
        }
        textures[id.rawValue] = TextureRecord(texture: texture, view: view, bindGroup: bindGroup)

        // `wgpuQueueWriteTexture` only stages the bytes; they stay resident until
        // the next submit. At launch hundreds of textures register before any
        // frame is submitted, so flush per texture or the staging copies of the
        // whole art set (~1 GB) pile up.
        wgpuQueueSubmit(queue, 0, nil)
        _ = wgpuDevicePoll(device, 0, nil)
    }

    /// Overwrite a horizontal band of an existing texture (dynamic glyph
    /// atlas). `y` and `height` are rows from the top; the band spans the full
    /// texture width so `bytesPerRow` stays copy-aligned.
    public func updateTexture(_ id: TextureID, rgba: [UInt8], y: Int, width: Int, height: Int) {
        guard height > 0, width > 0, rgba.count >= width * height * 4,
              let record = textures[id.rawValue] else { return }
        var destination = WGPUTexelCopyTextureInfo()
        destination.texture = record.texture
        destination.aspect = WGPUTextureAspect_All
        destination.origin = WGPUOrigin3D(x: 0, y: UInt32(max(0, y)), z: 0)
        var layout = WGPUTexelCopyBufferLayout()
        layout.bytesPerRow = UInt32(width * 4)
        layout.rowsPerImage = UInt32(height)
        var extent = WGPUExtent3D(width: UInt32(width), height: UInt32(height), depthOrArrayLayers: 1)
        rgba.withUnsafeBytes { bytes in
            wgpuQueueWriteTexture(queue, &destination, bytes.baseAddress, bytes.count, &layout, &extent)
        }
    }

    public func removeTexture(_ id: TextureID) {
        guard let record = textures.removeValue(forKey: id.rawValue) else { return }
        wgpuBindGroupRelease(record.bindGroup)
        wgpuTextureViewRelease(record.view)
        wgpuTextureRelease(record.texture)
    }

    public func hasTexture(_ id: TextureID) -> Bool { textures[id.rawValue] != nil }

    public func render(_ frame: CompiledFrame) { render(frame, time: 0) }

    public func render(_ frame: CompiledFrame, time: Float) {
        withDrawable { surfaceView, encoder in
            encodeFrame(frame, time: time, into: surfaceView, encoder: encoder)
        }
    }

    private func encodeFrame(_ frame: CompiledFrame, time: Float,
                             into surfaceView: WGPUTextureView, encoder: WGPUCommandEncoder) {
        releaseTransientPostResources()
        releaseTransientGeometryBuffers()
        advanceX3DClock(time)
        _ = upload(frame.shapeVertices, into: &vertexBuffer, capacity: &vertexBufferCapacity)
        _ = upload(frame.spriteVertices, into: &spriteVertexBuffer, capacity: &spriteVertexBufferCapacity)
        _ = upload(frame.fontVertices, into: &fontVertexBuffer, capacity: &fontVertexBufferCapacity)

        let effectiveIntensity = postIntensity * frame.postIntensity
        let usePost = (effectiveIntensity > 0 || !frame.shaderRegions.isEmpty || !frame.shaderLayers.isEmpty || !frame.x3d.isEmpty)
            && ensurePostResources()
        let sceneTarget = usePost ? (sceneView ?? surfaceView) : surfaceView

        let rootGeometry = GeometryBuffers(shapes: vertexBuffer, sprites: spriteVertexBuffer, fonts: fontVertexBuffer)
        drawScene(frame, geometry: rootGeometry, into: sceneTarget, encoder: encoder,
                  clear: frame.background, time: time, depth: 0)
        if usePost, let sceneView {
            runPost(into: surfaceView, sceneView: sceneView, time: time,
                    intensity: effectiveIntensity, regions: frame.shaderRegions, encoder: encoder)
        }
    }

    /// Renders `frame` into an offscreen `width`×`height` target through the
    /// exact pipelines the window uses (sprite/SDF-font/post/shader layers) and
    /// returns tightly packed, top-down **RGBA8** pixels. Blocks until the GPU
    /// finishes. Sprite/font textures must already be registered.
    public func renderToImage(_ frame: CompiledFrame, width: Int, height: Int, time: Float = 0) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        // Sprite/font pipelines are built lazily; a text-only frame needs them.
        _ = ensureSpriteResources()
        configure(width: UInt32(width), height: UInt32(height))

        var descriptor = WGPUTextureDescriptor()
        descriptor.usage = WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_CopySrc
        descriptor.dimension = WGPUTextureDimension_2D
        descriptor.size = WGPUExtent3D(width: UInt32(width), height: UInt32(height), depthOrArrayLayers: 1)
        descriptor.format = surfaceFormat
        descriptor.mipLevelCount = 1
        descriptor.sampleCount = 1
        guard let target = wgpuDeviceCreateTexture(device, &descriptor) else { return nil }
        defer { wgpuTextureRelease(target) }
        guard let view = wgpuTextureCreateView(target, nil) else { return nil }
        defer { wgpuTextureViewRelease(view) }

        // Copy rows must start on a 256-byte boundary.
        let packedRow = width * 4
        let paddedRow = (packedRow + 255) / 256 * 256
        var bufferDescriptor = WGPUBufferDescriptor()
        bufferDescriptor.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst
        bufferDescriptor.size = UInt64(paddedRow * height)
        guard let readback = wgpuDeviceCreateBuffer(device, &bufferDescriptor) else { return nil }
        defer { wgpuBufferRelease(readback) }

        guard let encoder = wgpuDeviceCreateCommandEncoder(device, nil) else { return nil }
        defer { wgpuCommandEncoderRelease(encoder) }
        encodeFrame(frame, time: time, into: view, encoder: encoder)

        var source = WGPUTexelCopyTextureInfo()
        source.texture = target
        source.mipLevel = 0
        source.origin = WGPUOrigin3D(x: 0, y: 0, z: 0)
        source.aspect = WGPUTextureAspect_All
        var destination = WGPUTexelCopyBufferInfo()
        destination.buffer = readback
        destination.layout.offset = 0
        destination.layout.bytesPerRow = UInt32(paddedRow)
        destination.layout.rowsPerImage = UInt32(height)
        var extent = WGPUExtent3D(width: UInt32(width), height: UInt32(height), depthOrArrayLayers: 1)
        wgpuCommandEncoderCopyTextureToBuffer(encoder, &source, &destination, &extent)

        guard let commandBuffer = wgpuCommandEncoderFinish(encoder, nil) else { return nil }
        var submitted: WGPUCommandBuffer? = commandBuffer
        withUnsafePointer(to: &submitted) { wgpuQueueSubmit(queue, 1, $0) }
        wgpuCommandBufferRelease(commandBuffer)

        guard mapSync(readback, size: paddedRow * height),
              let mapped = wgpuBufferGetConstMappedRange(readback, 0, paddedRow * height) else { return nil }
        defer { wgpuBufferUnmap(readback) }
        let bytes = mapped.assumingMemoryBound(to: UInt8.self)

        // BGRA (surface format) → RGBA, dropping the row padding.
        var out = [UInt8](repeating: 0, count: packedRow * height)
        for y in 0..<height {
            let src = bytes + y * paddedRow
            let dst = y * packedRow
            for x in 0..<width {
                out[dst + x * 4] = src[x * 4 + 2]
                out[dst + x * 4 + 1] = src[x * 4 + 1]
                out[dst + x * 4 + 2] = src[x * 4]
                out[dst + x * 4 + 3] = src[x * 4 + 3]
            }
        }
        return out
    }

    /// Encodes and submits `frame` offscreen without reading it back, so
    /// headless callers can advance stateful X3D programs cheaply.
    public func advanceOffscreen(_ frame: CompiledFrame, width: Int, height: Int, time: Float) {
        guard width > 0, height > 0 else { return }
        _ = ensureSpriteResources()
        configure(width: UInt32(width), height: UInt32(height))
        var descriptor = WGPUTextureDescriptor()
        descriptor.usage = WGPUTextureUsage_RenderAttachment
        descriptor.dimension = WGPUTextureDimension_2D
        descriptor.size = WGPUExtent3D(width: UInt32(width), height: UInt32(height), depthOrArrayLayers: 1)
        descriptor.format = surfaceFormat
        descriptor.mipLevelCount = 1
        descriptor.sampleCount = 1
        guard let target = wgpuDeviceCreateTexture(device, &descriptor) else { return }
        defer { wgpuTextureRelease(target) }
        guard let view = wgpuTextureCreateView(target, nil) else { return }
        defer { wgpuTextureViewRelease(view) }
        guard let encoder = wgpuDeviceCreateCommandEncoder(device, nil) else { return }
        defer { wgpuCommandEncoderRelease(encoder) }
        encodeFrame(frame, time: time, into: view, encoder: encoder)
        guard let commandBuffer = wgpuCommandEncoderFinish(encoder, nil) else { return }
        var submitted: WGPUCommandBuffer? = commandBuffer
        withUnsafePointer(to: &submitted) { wgpuQueueSubmit(queue, 1, $0) }
        wgpuCommandBufferRelease(commandBuffer)
        _ = wgpuDevicePoll(device, 1, nil)
    }

    private final class MapBox { var status = WGPUMapAsyncStatus_Error; var done = false }

    /// `wgpuBufferMapAsync` made synchronous: poll the device until the map
    /// callback fires.
    private func mapSync(_ buffer: WGPUBuffer, size: Int) -> Bool {
        let box = MapBox()
        var info = WGPUBufferMapCallbackInfo()
        info.mode = WGPUCallbackMode_AllowProcessEvents
        info.callback = { status, _, ud1, _ in
            let box = Unmanaged<MapBox>.fromOpaque(ud1!).takeUnretainedValue()
            box.status = status
            box.done = true
        }
        info.userdata1 = Unmanaged.passUnretained(box).toOpaque()
        _ = wgpuBufferMapAsync(buffer, WGPUMapMode_Read, 0, size, info)
        var spins = 0
        while !box.done && spins < 100_000 {
            _ = wgpuDevicePoll(device, 1, nil)
            wgpuInstanceProcessEvents(instance)
            spins += 1
        }
        return box.done && box.status == WGPUMapAsyncStatus_Success
    }

    func drawScene(
        _ frame: CompiledFrame,
        geometry: GeometryBuffers,
        into targetView: WGPUTextureView,
        encoder: WGPUCommandEncoder,
        clear: RenderColor?,
        time: Float,
        depth: Int
    ) {
        let stride = MemoryLayout<Float>.stride
        func beginPass(load: Bool) -> WGPURenderPassEncoder? {
            var attachment = WGPURenderPassColorAttachment()
            attachment.view = targetView
            attachment.depthSlice = UInt32.max
            attachment.loadOp = load ? WGPULoadOp_Load : WGPULoadOp_Clear
            attachment.storeOp = WGPUStoreOp_Store
            let clearColor = clear ?? RenderColor(0, 0, 0, 0)
            attachment.clearValue = WGPUColor(
                r: Double(clearColor.red), g: Double(clearColor.green),
                b: Double(clearColor.blue), a: Double(clearColor.alpha)
            )
            return withUnsafePointer(to: &attachment) { attachmentPointer in
                var descriptor = WGPURenderPassDescriptor()
                descriptor.colorAttachmentCount = 1
                descriptor.colorAttachments = attachmentPointer
                return wgpuCommandEncoderBeginRenderPass(encoder, &descriptor)
            }
        }
        var pass = beginPass(load: clear == nil)
        guard pass != nil else { return }
        for draw in frame.draws {
            guard let activePass = pass else { return }
            switch draw {
            case .shapes(let range, let scissor):
                guard let vertexBuffer = geometry.shapes, !range.isEmpty else { continue }
                wgpuRenderPassEncoderSetPipeline(activePass, pipeline)
                wgpuRenderPassEncoderSetVertexBuffer(activePass, 0, vertexBuffer,
                    UInt64(range.lowerBound * 6 * stride), UInt64(range.count * 6 * stride))
                applyScissor(activePass, scissor)
                wgpuRenderPassEncoderDraw(activePass, UInt32(range.count), 1, 0, 0)
            case .sprite(let textureID, let range, let scissor):
                guard let spritePipeline, let spriteVertexBuffer = geometry.sprites, !range.isEmpty,
                      let record = textures[textureID.rawValue] else { continue }
                wgpuRenderPassEncoderSetPipeline(activePass, spritePipeline)
                wgpuRenderPassEncoderSetBindGroup(activePass, 0, record.bindGroup, 0, nil)
                wgpuRenderPassEncoderSetVertexBuffer(activePass, 0, spriteVertexBuffer,
                    UInt64(range.lowerBound * 8 * stride), UInt64(range.count * 8 * stride))
                applyScissor(activePass, scissor)
                wgpuRenderPassEncoderDraw(activePass, UInt32(range.count), 1, 0, 0)
            case .font(let textureID, let range, let scissor):
                guard let fontPipeline, let fontVertexBuffer = geometry.fonts, !range.isEmpty,
                      let record = textures[textureID.rawValue] else { continue }
                wgpuRenderPassEncoderSetPipeline(activePass, fontPipeline)
                wgpuRenderPassEncoderSetBindGroup(activePass, 0, record.bindGroup, 0, nil)
                wgpuRenderPassEncoderSetVertexBuffer(activePass, 0, fontVertexBuffer,
                    UInt64(range.lowerBound * 14 * stride), UInt64(range.count * 14 * stride))
                applyScissor(activePass, scissor)
                wgpuRenderPassEncoderDraw(activePass, UInt32(range.count), 1, 0, 0)
            case .material:
                // The command path preserves material order now. Execution
                // belongs to the forthcoming XUI-native material renderer.
                continue
            case .x3d(let index):
                guard frame.x3d.indices.contains(index), let activePass = pass else { continue }
                wgpuRenderPassEncoderEnd(activePass)
                pass = nil
                encodeX3D(frame.x3d[index], parent: targetView, encoder: encoder, depth: depth)
                pass = beginPass(load: true)
                guard pass != nil else { return }
            case .shaderLayer(let index):
                guard frame.shaderLayers.indices.contains(index), let activePass = pass else { continue }
                wgpuRenderPassEncoderEnd(activePass)
                pass = nil
                let layer = frame.shaderLayers[index]
                guard let target = ensureShaderLayerTarget(at: depth) else { return }
                let layerGeometry = makeTransientGeometryBuffers(for: layer.frame)
                drawScene(layer.frame, geometry: layerGeometry, into: target.view, encoder: encoder,
                          clear: RenderColor(0, 0, 0, 0), time: time, depth: depth + 1)
                runLayerPost(into: targetView, sourceView: target.view, time: time,
                             layer: layer, encoder: encoder)
                pass = beginPass(load: true)
                guard pass != nil else { return }
            }
        }
        if let pass {
            wgpuRenderPassEncoderEnd(pass)
            wgpuRenderPassEncoderRelease(pass)
        }
    }

    private func runPost(
        into surfaceView: WGPUTextureView,
        sceneView: WGPUTextureView,
        time: Float,
        intensity: Float,
        regions: [CompiledShaderRegion],
        encoder: WGPUCommandEncoder
    ) {
        guard let postPipeline, let postBindGroup, let postUniformBuffer else { return }
        var uniforms = Array(repeating: Float(0), count: Self.postUniformFloatCount)
        uniforms[0] = Float(configuredWidth)
        uniforms[1] = Float(configuredHeight)
        uniforms[2] = time
        uniforms[3] = intensity
        uniforms[4] = Float(min(regions.count, Self.maxShaderRegions))
        for (index, region) in regions.prefix(Self.maxShaderRegions).enumerated() {
            let base = 8 + index * 12
            uniforms[base] = Float(region.rect.x)
            uniforms[base + 1] = Float(region.rect.y)
            uniforms[base + 2] = Float(region.rect.width)
            uniforms[base + 3] = Float(region.rect.height)
            for (offset, value) in region.shader.uniforms.values.prefix(4).enumerated() {
                uniforms[base + 4 + offset] = value
            }
            uniforms[base + 8] = Self.shaderKind(for: region.shader.key)
        }
        uniforms[5] = 0
        uniforms.withUnsafeBytes { wgpuQueueWriteBuffer(queue, postUniformBuffer, 0, $0.baseAddress, $0.count) }

        var attachment = WGPURenderPassColorAttachment()
        attachment.view = surfaceView
        attachment.depthSlice = UInt32.max
        attachment.loadOp = WGPULoadOp_Clear
        attachment.storeOp = WGPUStoreOp_Store
        attachment.clearValue = WGPUColor(r: 0, g: 0, b: 0, a: 1)
        withUnsafePointer(to: &attachment) { attachmentPointer in
            var passDescriptor = WGPURenderPassDescriptor()
            passDescriptor.colorAttachmentCount = 1
            passDescriptor.colorAttachments = attachmentPointer
            guard let pass = wgpuCommandEncoderBeginRenderPass(encoder, &passDescriptor) else { return }
            wgpuRenderPassEncoderSetPipeline(pass, postPipeline)
            wgpuRenderPassEncoderSetBindGroup(pass, 0, postBindGroup, 0, nil)
            wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0)
            wgpuRenderPassEncoderEnd(pass)
            wgpuRenderPassEncoderRelease(pass)
        }
    }

    /// Apply one `.layer` shader to an isolated transparent texture and alpha
    /// composite it over the already-painted parent target.
    func runLayerPost(
        into targetView: WGPUTextureView,
        sourceView: WGPUTextureView,
        time: Float,
        layer: CompiledShaderLayer,
        encoder: WGPUCommandEncoder
    ) {
        guard let postPipeline, let postSampler, let postBindGroupLayout else { return }
        var uniforms = Array(repeating: Float(0), count: Self.postUniformFloatCount)
        uniforms[0] = Float(configuredWidth)
        uniforms[1] = Float(configuredHeight)
        uniforms[2] = time
        uniforms[4] = 1
        uniforms[5] = 1
        uniforms[8] = Float(layer.rect.x)
        uniforms[9] = Float(layer.rect.y)
        uniforms[10] = Float(layer.rect.width)
        uniforms[11] = Float(layer.rect.height)
        for (offset, value) in layer.shader.uniforms.values.prefix(4).enumerated() {
            uniforms[12 + offset] = value
        }
        uniforms[16] = Self.shaderKind(for: layer.shader.key)

        var bufferDescriptor = WGPUBufferDescriptor()
        bufferDescriptor.usage = WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst
        bufferDescriptor.size = UInt64(Self.postUniformFloatCount * MemoryLayout<Float>.stride)
        guard let uniform = wgpuDeviceCreateBuffer(device, &bufferDescriptor) else { return }
        uniforms.withUnsafeBytes { wgpuQueueWriteBuffer(queue, uniform, 0, $0.baseAddress, $0.count) }

        var entries = [WGPUBindGroupEntry(), WGPUBindGroupEntry(), WGPUBindGroupEntry()]
        entries[0].binding = 0; entries[0].textureView = sourceView
        entries[1].binding = 1; entries[1].sampler = postSampler
        entries[2].binding = 2; entries[2].buffer = uniform
        entries[2].size = UInt64(Self.postUniformFloatCount * MemoryLayout<Float>.stride)
        let bindGroup = entries.withUnsafeBufferPointer { pointer -> WGPUBindGroup? in
            var descriptor = WGPUBindGroupDescriptor()
            descriptor.layout = postBindGroupLayout
            descriptor.entryCount = pointer.count
            descriptor.entries = pointer.baseAddress
            return wgpuDeviceCreateBindGroup(device, &descriptor)
        }
        guard let bindGroup else { wgpuBufferRelease(uniform); return }
        transientPostUniformBuffers.append(uniform)
        transientPostBindGroups.append(bindGroup)

        var attachment = WGPURenderPassColorAttachment()
        attachment.view = targetView
        attachment.depthSlice = UInt32.max
        attachment.loadOp = WGPULoadOp_Load
        attachment.storeOp = WGPUStoreOp_Store
        withUnsafePointer(to: &attachment) { attachmentPointer in
            var descriptor = WGPURenderPassDescriptor()
            descriptor.colorAttachmentCount = 1
            descriptor.colorAttachments = attachmentPointer
            guard let pass = wgpuCommandEncoderBeginRenderPass(encoder, &descriptor) else { return }
            wgpuRenderPassEncoderSetPipeline(pass, postPipeline)
            wgpuRenderPassEncoderSetBindGroup(pass, 0, bindGroup, 0, nil)
            applyScissor(pass, layer.rect)
            wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0)
            wgpuRenderPassEncoderEnd(pass)
            wgpuRenderPassEncoderRelease(pass)
        }
    }

    func ensureShaderLayerTarget(at depth: Int) -> LayerTarget? {
        while shaderLayerTargets.count <= depth {
            var descriptor = WGPUTextureDescriptor()
            descriptor.usage = WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_TextureBinding
            descriptor.dimension = WGPUTextureDimension_2D
            descriptor.size = WGPUExtent3D(width: configuredWidth, height: configuredHeight, depthOrArrayLayers: 1)
            descriptor.format = surfaceFormat
            descriptor.mipLevelCount = 1
            descriptor.sampleCount = 1
            guard let texture = wgpuDeviceCreateTexture(device, &descriptor) else { return nil }
            guard let view = wgpuTextureCreateView(texture, nil) else {
                wgpuTextureRelease(texture)
                return nil
            }
            shaderLayerTargets.append(LayerTarget(texture: texture, view: view))
        }
        return shaderLayerTargets[depth]
    }

    private func releaseShaderLayerTargets() {
        for target in shaderLayerTargets {
            wgpuTextureViewRelease(target.view)
            wgpuTextureRelease(target.texture)
        }
        shaderLayerTargets.removeAll(keepingCapacity: false)
    }

    private func releaseTransientPostResources() {
        for bindGroup in transientPostBindGroups { wgpuBindGroupRelease(bindGroup) }
        for buffer in transientPostUniformBuffers { wgpuBufferRelease(buffer) }
        transientPostBindGroups.removeAll(keepingCapacity: true)
        transientPostUniformBuffers.removeAll(keepingCapacity: true)
    }

    func makeTransientGeometryBuffers(for frame: CompiledFrame) -> GeometryBuffers {
        GeometryBuffers(
            shapes: makeTransientVertexBuffer(frame.shapeVertices),
            sprites: makeTransientVertexBuffer(frame.spriteVertices),
            fonts: makeTransientVertexBuffer(frame.fontVertices)
        )
    }

    private func makeTransientVertexBuffer(_ values: [Float]) -> WGPUBuffer? {
        guard !values.isEmpty else { return nil }
        var descriptor = WGPUBufferDescriptor()
        descriptor.usage = WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst
        descriptor.size = UInt64(values.count * MemoryLayout<Float>.stride)
        guard let buffer = wgpuDeviceCreateBuffer(device, &descriptor) else { return nil }
        values.withUnsafeBytes { wgpuQueueWriteBuffer(queue, buffer, 0, $0.baseAddress, $0.count) }
        transientGeometryBuffers.append(buffer)
        return buffer
    }

    private func releaseTransientGeometryBuffers() {
        for buffer in transientGeometryBuffers { wgpuBufferRelease(buffer) }
        transientGeometryBuffers.removeAll(keepingCapacity: true)
    }

    private static func shaderKind(for key: ShaderKey) -> Float {
        switch key {
        case ShaderLibrary.cellGlowKey: return 1
        case ShaderLibrary.cellShineKey: return 2
        case ShaderLibrary.hitFlashKey: return 3
        case ShaderLibrary.glassKey: return 4
        case ShaderLibrary.vhsKey: return 5
        case ShaderLibrary.foilKey: return 6
        case ShaderLibrary.lenticularKey: return 7
        case ShaderLibrary.warpKey: return 8
        default: return 0
        }
    }

    func applyScissor(_ pass: WGPURenderPassEncoder, _ rect: PixelRect?) {
        guard let rect else {
            wgpuRenderPassEncoderSetScissorRect(pass, 0, 0, configuredWidth, configuredHeight)
            return
        }
        let x = min(rect.x, configuredWidth)
        let y = min(rect.y, configuredHeight)
        wgpuRenderPassEncoderSetScissorRect(
            pass, x, y, min(rect.width, configuredWidth - x), min(rect.height, configuredHeight - y)
        )
    }

    private func upload(_ floats: [Float], into buffer: inout WGPUBuffer?, capacity: inout Int) -> Int {
        let byteCount = floats.count * MemoryLayout<Float>.stride
        guard byteCount > 0 else { return 0 }
        if byteCount > capacity {
            if let buffer { wgpuBufferRelease(buffer) }
            capacity = max(byteCount, max(65_536, capacity * 2))
            var descriptor = WGPUBufferDescriptor()
            descriptor.usage = WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst
            descriptor.size = UInt64(capacity)
            buffer = wgpuDeviceCreateBuffer(device, &descriptor)
        }
        if let buffer {
            floats.withUnsafeBytes { wgpuQueueWriteBuffer(queue, buffer, 0, $0.baseAddress, $0.count) }
        }
        return byteCount
    }

    /// Builds the sprite shader, sampler, bind-group layout and pipeline on
    /// first use. Returns false (and leaves the sprite path disabled) on failure.
    private func ensureSpriteResources() -> Bool {
        if spritePipeline != nil { return true }

        var samplerDescriptor = WGPUSamplerDescriptor()
        samplerDescriptor.addressModeU = WGPUAddressMode_ClampToEdge
        samplerDescriptor.addressModeV = WGPUAddressMode_ClampToEdge
        samplerDescriptor.addressModeW = WGPUAddressMode_ClampToEdge
        samplerDescriptor.magFilter = WGPUFilterMode_Linear
        samplerDescriptor.minFilter = WGPUFilterMode_Linear
        samplerDescriptor.mipmapFilter = WGPUMipmapFilterMode_Linear
        samplerDescriptor.lodMaxClamp = 32
        samplerDescriptor.maxAnisotropy = 1
        guard let sampler = wgpuDeviceCreateSampler(device, &samplerDescriptor) else { return false }

        var layoutEntries = [WGPUBindGroupLayoutEntry(), WGPUBindGroupLayoutEntry()]
        layoutEntries[0].binding = 0
        layoutEntries[0].visibility = WGPUShaderStage_Fragment
        layoutEntries[0].texture.sampleType = WGPUTextureSampleType_Float
        layoutEntries[0].texture.viewDimension = WGPUTextureViewDimension_2D
        layoutEntries[1].binding = 1
        layoutEntries[1].visibility = WGPUShaderStage_Fragment
        layoutEntries[1].sampler.type = WGPUSamplerBindingType_Filtering
        let bindGroupLayout = layoutEntries.withUnsafeBufferPointer { pointer -> WGPUBindGroupLayout? in
            var descriptor = WGPUBindGroupLayoutDescriptor()
            descriptor.entryCount = pointer.count
            descriptor.entries = pointer.baseAddress
            return wgpuDeviceCreateBindGroupLayout(device, &descriptor)
        }
        guard let bindGroupLayout else {
            wgpuSamplerRelease(sampler); return false
        }

        let layouts: [WGPUBindGroupLayout?] = [bindGroupLayout]
        let pipelineLayout: WGPUPipelineLayout? = layouts.withUnsafeBufferPointer { pointer in
            var descriptor = WGPUPipelineLayoutDescriptor()
            descriptor.bindGroupLayoutCount = pointer.count
            descriptor.bindGroupLayouts = pointer.baseAddress
            return wgpuDeviceCreatePipelineLayout(device, &descriptor)
        }
        guard let pipelineLayout,
              let shaderModule = Self.makeShaderModule(device: device, wgsl: spriteWGSL),
              let pipeline = Self.makeSpritePipeline(
                device: device, shader: shaderModule, layout: pipelineLayout, format: surfaceFormat
              ),
              let fontModule = Self.makeShaderModule(device: device, wgsl: fontWGSL),
              let fontPipeline = Self.makeFontPipeline(
                device: device, shader: fontModule, layout: pipelineLayout, format: surfaceFormat
              ) else {
            wgpuBindGroupLayoutRelease(bindGroupLayout); wgpuSamplerRelease(sampler)
            return false
        }
        wgpuPipelineLayoutRelease(pipelineLayout)

        spriteSampler = sampler
        spriteBindGroupLayout = bindGroupLayout
        spriteShader = shaderModule
        spritePipeline = pipeline
        fontShader = fontModule
        self.fontPipeline = fontPipeline
        return true
    }

    /// Builds the offscreen scene texture (re-created on resize), the post
    /// sampler/uniform/pipeline, and the bind group. False disables the pass.
    private func ensurePostResources() -> Bool {
        if sceneTexture == nil || sceneTextureWidth != configuredWidth || sceneTextureHeight != configuredHeight {
            if let sceneView { wgpuTextureViewRelease(sceneView) }
            if let sceneTexture { wgpuTextureRelease(sceneTexture) }
            if let postBindGroup { wgpuBindGroupRelease(postBindGroup); self.postBindGroup = nil }
            sceneView = nil; sceneTexture = nil

            var descriptor = WGPUTextureDescriptor()
            descriptor.usage = WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_TextureBinding
            descriptor.dimension = WGPUTextureDimension_2D
            descriptor.size = WGPUExtent3D(width: configuredWidth, height: configuredHeight, depthOrArrayLayers: 1)
            descriptor.format = surfaceFormat
            descriptor.mipLevelCount = 1
            descriptor.sampleCount = 1
            guard let tex = wgpuDeviceCreateTexture(device, &descriptor),
                  let view = wgpuTextureCreateView(tex, nil) else { return false }
            sceneTexture = tex
            sceneView = view
            sceneTextureWidth = configuredWidth
            sceneTextureHeight = configuredHeight
        }

        if postPipeline == nil {
            var samplerDescriptor = WGPUSamplerDescriptor()
            samplerDescriptor.addressModeU = WGPUAddressMode_ClampToEdge
            samplerDescriptor.addressModeV = WGPUAddressMode_ClampToEdge
            samplerDescriptor.addressModeW = WGPUAddressMode_ClampToEdge
            samplerDescriptor.magFilter = WGPUFilterMode_Linear
            samplerDescriptor.minFilter = WGPUFilterMode_Linear
            samplerDescriptor.mipmapFilter = WGPUMipmapFilterMode_Nearest
            samplerDescriptor.lodMaxClamp = 32
            samplerDescriptor.maxAnisotropy = 1
            guard let sampler = wgpuDeviceCreateSampler(device, &samplerDescriptor) else { return false }

            var bufferDescriptor = WGPUBufferDescriptor()
            bufferDescriptor.usage = WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst
            bufferDescriptor.size = UInt64(Self.postUniformFloatCount * MemoryLayout<Float>.stride)
            guard let uniform = wgpuDeviceCreateBuffer(device, &bufferDescriptor) else {
                wgpuSamplerRelease(sampler); return false
            }

            var layoutEntries = [WGPUBindGroupLayoutEntry(), WGPUBindGroupLayoutEntry(), WGPUBindGroupLayoutEntry()]
            layoutEntries[0].binding = 0
            layoutEntries[0].visibility = WGPUShaderStage_Fragment
            layoutEntries[0].texture.sampleType = WGPUTextureSampleType_Float
            layoutEntries[0].texture.viewDimension = WGPUTextureViewDimension_2D
            layoutEntries[1].binding = 1
            layoutEntries[1].visibility = WGPUShaderStage_Fragment
            layoutEntries[1].sampler.type = WGPUSamplerBindingType_Filtering
            layoutEntries[2].binding = 2
            layoutEntries[2].visibility = WGPUShaderStage_Fragment
            layoutEntries[2].buffer.type = WGPUBufferBindingType_Uniform
            let bindGroupLayout = layoutEntries.withUnsafeBufferPointer { pointer -> WGPUBindGroupLayout? in
                var descriptor = WGPUBindGroupLayoutDescriptor()
                descriptor.entryCount = pointer.count
                descriptor.entries = pointer.baseAddress
                return wgpuDeviceCreateBindGroupLayout(device, &descriptor)
            }
            guard let bindGroupLayout else { wgpuSamplerRelease(sampler); wgpuBufferRelease(uniform); return false }

            let layouts: [WGPUBindGroupLayout?] = [bindGroupLayout]
            let pipelineLayout: WGPUPipelineLayout? = layouts.withUnsafeBufferPointer { pointer in
                var descriptor = WGPUPipelineLayoutDescriptor()
                descriptor.bindGroupLayoutCount = pointer.count
                descriptor.bindGroupLayouts = pointer.baseAddress
                return wgpuDeviceCreatePipelineLayout(device, &descriptor)
            }
            guard let pipelineLayout,
                  let shaderModule = Self.makeShaderModule(device: device, wgsl: postWGSL),
                  let pipeline = Self.makePostPipeline(device: device, shader: shaderModule,
                                                      layout: pipelineLayout, format: surfaceFormat) else {
                wgpuBindGroupLayoutRelease(bindGroupLayout); wgpuSamplerRelease(sampler); wgpuBufferRelease(uniform)
                return false
            }
            wgpuPipelineLayoutRelease(pipelineLayout)
            postSampler = sampler
            postUniformBuffer = uniform
            postBindGroupLayout = bindGroupLayout
            postShader = shaderModule
            postPipeline = pipeline
        }

        if postBindGroup == nil, let sceneView, let postSampler, let postUniformBuffer, let postBindGroupLayout {
            var entries = [WGPUBindGroupEntry(), WGPUBindGroupEntry(), WGPUBindGroupEntry()]
            entries[0].binding = 0
            entries[0].textureView = sceneView
            entries[1].binding = 1
            entries[1].sampler = postSampler
            entries[2].binding = 2
            entries[2].buffer = postUniformBuffer
            entries[2].size = UInt64(Self.postUniformFloatCount * MemoryLayout<Float>.stride)
            postBindGroup = entries.withUnsafeBufferPointer { pointer -> WGPUBindGroup? in
                var descriptor = WGPUBindGroupDescriptor()
                descriptor.layout = postBindGroupLayout
                descriptor.entryCount = pointer.count
                descriptor.entries = pointer.baseAddress
                return wgpuDeviceCreateBindGroup(device, &descriptor)
            }
        }
        return postPipeline != nil && postBindGroup != nil
    }

    static func makeShaderModule(device: WGPUDevice, wgsl: String) -> WGPUShaderModule? {
        withWGPUString(wgsl) { code in
            var source = WGPUShaderSourceWGSL()
            source.chain.sType = WGPUSType_ShaderSourceWGSL
            source.code = code
            return withChained(&source) { chain in
                var descriptor = WGPUShaderModuleDescriptor()
                descriptor.nextInChain = chain
                return wgpuDeviceCreateShaderModule(device, &descriptor)
            }
        }
    }

    private static func makePipeline(
        device: WGPUDevice,
        shader: WGPUShaderModule,
        format: WGPUTextureFormat
    ) -> WGPURenderPipeline? {
        withWGPUString("vs_main") { vertexEntry in
            withWGPUString("fs_main") { fragmentEntry in
                var attributes = [WGPUVertexAttribute(), WGPUVertexAttribute()]
                attributes[0].format = WGPUVertexFormat_Float32x2
                attributes[0].offset = 0
                attributes[0].shaderLocation = 0
                attributes[1].format = WGPUVertexFormat_Float32x4
                attributes[1].offset = 2 * UInt64(MemoryLayout<Float>.stride)
                attributes[1].shaderLocation = 1

                return attributes.withUnsafeBufferPointer { attributePointer in
                    var bufferLayout = WGPUVertexBufferLayout()
                    bufferLayout.stepMode = WGPUVertexStepMode_Vertex
                    bufferLayout.arrayStride = 6 * UInt64(MemoryLayout<Float>.stride)
                    bufferLayout.attributeCount = attributes.count
                    bufferLayout.attributes = attributePointer.baseAddress

                    return withUnsafePointer(to: &bufferLayout) { bufferPointer in
                        var blend = WGPUBlendState()
                        blend.color.operation = WGPUBlendOperation_Add
                        blend.color.srcFactor = WGPUBlendFactor_SrcAlpha
                        blend.color.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha
                        blend.alpha.operation = WGPUBlendOperation_Add
                        blend.alpha.srcFactor = WGPUBlendFactor_One
                        blend.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha

                        return withUnsafePointer(to: &blend) { blendPointer in
                            var target = WGPUColorTargetState()
                            target.format = format
                            target.blend = blendPointer
                            target.writeMask = WGPUColorWriteMask_All

                            return withUnsafePointer(to: &target) { targetPointer in
                                var fragment = WGPUFragmentState()
                                fragment.module = shader
                                fragment.entryPoint = fragmentEntry
                                fragment.targetCount = 1
                                fragment.targets = targetPointer

                                return withUnsafePointer(to: &fragment) { fragmentPointer in
                                    var descriptor = WGPURenderPipelineDescriptor()
                                    descriptor.vertex.module = shader
                                    descriptor.vertex.entryPoint = vertexEntry
                                    descriptor.vertex.bufferCount = 1
                                    descriptor.vertex.buffers = bufferPointer
                                    descriptor.primitive.topology = WGPUPrimitiveTopology_TriangleList
                                    descriptor.primitive.frontFace = WGPUFrontFace_CCW
                                    descriptor.primitive.cullMode = WGPUCullMode_None
                                    descriptor.multisample.count = 1
                                    descriptor.multisample.mask = UInt32.max
                                    descriptor.fragment = fragmentPointer
                                    return wgpuDeviceCreateRenderPipeline(device, &descriptor)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Sprite pipeline: vertex `pos(2) + uv(2) + tint(4)` stride 32, premultiplied
    /// alpha blend, explicit layout carrying the texture+sampler bind group.
    private static func makeSpritePipeline(
        device: WGPUDevice,
        shader: WGPUShaderModule,
        layout: WGPUPipelineLayout,
        format: WGPUTextureFormat
    ) -> WGPURenderPipeline? {
        withWGPUString("vs_main") { vertexEntry in
            withWGPUString("fs_main") { fragmentEntry in
                let floatStride = UInt64(MemoryLayout<Float>.stride)
                var attributes = [WGPUVertexAttribute(), WGPUVertexAttribute(), WGPUVertexAttribute()]
                attributes[0].format = WGPUVertexFormat_Float32x2
                attributes[0].offset = 0
                attributes[0].shaderLocation = 0
                attributes[1].format = WGPUVertexFormat_Float32x2
                attributes[1].offset = 2 * floatStride
                attributes[1].shaderLocation = 1
                attributes[2].format = WGPUVertexFormat_Float32x4
                attributes[2].offset = 4 * floatStride
                attributes[2].shaderLocation = 2

                return attributes.withUnsafeBufferPointer { attributePointer in
                    var bufferLayout = WGPUVertexBufferLayout()
                    bufferLayout.stepMode = WGPUVertexStepMode_Vertex
                    bufferLayout.arrayStride = 8 * floatStride
                    bufferLayout.attributeCount = attributes.count
                    bufferLayout.attributes = attributePointer.baseAddress

                    return withUnsafePointer(to: &bufferLayout) { bufferPointer in
                        var blend = WGPUBlendState()
                        blend.color.operation = WGPUBlendOperation_Add
                        blend.color.srcFactor = WGPUBlendFactor_One
                        blend.color.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha
                        blend.alpha.operation = WGPUBlendOperation_Add
                        blend.alpha.srcFactor = WGPUBlendFactor_One
                        blend.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha

                        return withUnsafePointer(to: &blend) { blendPointer in
                            var target = WGPUColorTargetState()
                            target.format = format
                            target.blend = blendPointer
                            target.writeMask = WGPUColorWriteMask_All

                            return withUnsafePointer(to: &target) { targetPointer in
                                var fragment = WGPUFragmentState()
                                fragment.module = shader
                                fragment.entryPoint = fragmentEntry
                                fragment.targetCount = 1
                                fragment.targets = targetPointer

                                return withUnsafePointer(to: &fragment) { fragmentPointer in
                                    var descriptor = WGPURenderPipelineDescriptor()
                                    descriptor.layout = layout
                                    descriptor.vertex.module = shader
                                    descriptor.vertex.entryPoint = vertexEntry
                                    descriptor.vertex.bufferCount = 1
                                    descriptor.vertex.buffers = bufferPointer
                                    descriptor.primitive.topology = WGPUPrimitiveTopology_TriangleList
                                    descriptor.primitive.frontFace = WGPUFrontFace_CCW
                                    descriptor.primitive.cullMode = WGPUCullMode_None
                                    descriptor.multisample.count = 1
                                    descriptor.multisample.mask = UInt32.max
                                    descriptor.fragment = fragmentPointer
                                    return wgpuDeviceCreateRenderPipeline(device, &descriptor)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Font pipeline: one SDF quad pass draws both the outline and fill. Its
    /// vertices carry two premultiplied colors plus the outline width in atlas
    /// pixels; ordinary sprites stay on the lighter eight-float pipeline.
    private static func makeFontPipeline(
        device: WGPUDevice,
        shader: WGPUShaderModule,
        layout: WGPUPipelineLayout,
        format: WGPUTextureFormat
    ) -> WGPURenderPipeline? {
        withWGPUString("vs_main") { vertexEntry in
            withWGPUString("fs_main") { fragmentEntry in
                let floatStride = UInt64(MemoryLayout<Float>.stride)
                var attributes = [WGPUVertexAttribute(), WGPUVertexAttribute(), WGPUVertexAttribute(),
                                  WGPUVertexAttribute(), WGPUVertexAttribute(), WGPUVertexAttribute()]
                attributes[0].format = WGPUVertexFormat_Float32x2
                attributes[0].offset = 0
                attributes[0].shaderLocation = 0
                attributes[1].format = WGPUVertexFormat_Float32x2
                attributes[1].offset = 2 * floatStride
                attributes[1].shaderLocation = 1
                attributes[2].format = WGPUVertexFormat_Float32x4
                attributes[2].offset = 4 * floatStride
                attributes[2].shaderLocation = 2
                attributes[3].format = WGPUVertexFormat_Float32x4
                attributes[3].offset = 8 * floatStride
                attributes[3].shaderLocation = 3
                attributes[4].format = WGPUVertexFormat_Float32
                attributes[4].offset = 12 * floatStride
                attributes[4].shaderLocation = 4
                attributes[5].format = WGPUVertexFormat_Float32
                attributes[5].offset = 13 * floatStride
                attributes[5].shaderLocation = 5

                return attributes.withUnsafeBufferPointer { attributePointer in
                    var bufferLayout = WGPUVertexBufferLayout()
                    bufferLayout.stepMode = WGPUVertexStepMode_Vertex
                    bufferLayout.arrayStride = 14 * floatStride
                    bufferLayout.attributeCount = attributes.count
                    bufferLayout.attributes = attributePointer.baseAddress

                    return withUnsafePointer(to: &bufferLayout) { bufferPointer in
                        var blend = WGPUBlendState()
                        blend.color.operation = WGPUBlendOperation_Add
                        blend.color.srcFactor = WGPUBlendFactor_One
                        blend.color.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha
                        blend.alpha.operation = WGPUBlendOperation_Add
                        blend.alpha.srcFactor = WGPUBlendFactor_One
                        blend.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha
                        return withUnsafePointer(to: &blend) { blendPointer in
                            var target = WGPUColorTargetState()
                            target.format = format
                            target.blend = blendPointer
                            target.writeMask = WGPUColorWriteMask_All
                            return withUnsafePointer(to: &target) { targetPointer in
                                var fragment = WGPUFragmentState()
                                fragment.module = shader
                                fragment.entryPoint = fragmentEntry
                                fragment.targetCount = 1
                                fragment.targets = targetPointer
                                return withUnsafePointer(to: &fragment) { fragmentPointer in
                                    var descriptor = WGPURenderPipelineDescriptor()
                                    descriptor.layout = layout
                                    descriptor.vertex.module = shader
                                    descriptor.vertex.entryPoint = vertexEntry
                                    descriptor.vertex.bufferCount = 1
                                    descriptor.vertex.buffers = bufferPointer
                                    descriptor.primitive.topology = WGPUPrimitiveTopology_TriangleList
                                    descriptor.primitive.frontFace = WGPUFrontFace_CCW
                                    descriptor.primitive.cullMode = WGPUCullMode_None
                                    descriptor.multisample.count = 1
                                    descriptor.multisample.mask = UInt32.max
                                    descriptor.fragment = fragmentPointer
                                    return wgpuDeviceCreateRenderPipeline(device, &descriptor)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Post pipeline: no vertex buffers (a 3-vertex fullscreen triangle from
    /// `@builtin(vertex_index)`). It supports alpha blending so the same pass
    /// can composite an isolated view layer over its parent.
    private static func makePostPipeline(
        device: WGPUDevice, shader: WGPUShaderModule, layout: WGPUPipelineLayout, format: WGPUTextureFormat
    ) -> WGPURenderPipeline? {
        withWGPUString("vs_main") { vertexEntry in
            withWGPUString("fs_main") { fragmentEntry in
                var target = WGPUColorTargetState()
                target.format = format
                var blend = WGPUBlendState()
                blend.color.operation = WGPUBlendOperation_Add
                blend.color.srcFactor = WGPUBlendFactor_One
                blend.color.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha
                blend.alpha.operation = WGPUBlendOperation_Add
                blend.alpha.srcFactor = WGPUBlendFactor_One
                blend.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha
                return withUnsafePointer(to: &blend) { blendPointer in
                    target.blend = blendPointer
                    target.writeMask = WGPUColorWriteMask_All
                    return withUnsafePointer(to: &target) { targetPointer in
                        var fragment = WGPUFragmentState()
                        fragment.module = shader
                        fragment.entryPoint = fragmentEntry
                        fragment.targetCount = 1
                        fragment.targets = targetPointer
                        return withUnsafePointer(to: &fragment) { fragmentPointer in
                            var descriptor = WGPURenderPipelineDescriptor()
                            descriptor.layout = layout
                            descriptor.vertex.module = shader
                            descriptor.vertex.entryPoint = vertexEntry
                            descriptor.vertex.bufferCount = 0
                            descriptor.primitive.topology = WGPUPrimitiveTopology_TriangleList
                            descriptor.primitive.frontFace = WGPUFrontFace_CCW
                            descriptor.primitive.cullMode = WGPUCullMode_None
                            descriptor.multisample.count = 1
                            descriptor.multisample.mask = UInt32.max
                            descriptor.fragment = fragmentPointer
                            return wgpuDeviceCreateRenderPipeline(device, &descriptor)
                        }
                    }
                }
            }
        }
    }
}
