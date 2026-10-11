import CWGPU
import XRender
import XShader

/// Prepended to every X3D shader. `origin`/`resolution` are the pass's
/// viewport in target pixels; `@builtin(position)` stays in target pixels, so
/// `position.xy - x3d.origin` is viewport-local. Resources bound with
/// `.bind` live in `@group(1)`, numbered in bind order.
let x3dPreludeWGSL = """
struct X3DFrame {
    resolution: vec2<f32>,
    origin: vec2<f32>,
    time: f32,
    dt: f32,
    frame: u32,
    pad: u32,
    viewProjection: mat4x4<f32>,
    cameraPosition: vec4<f32>,
    model: mat4x4<f32>,
};
@group(0) @binding(0) var<uniform> x3d: X3DFrame;
@group(0) @binding(1) var<storage, read> x3dParams: array<f32>;
@group(0) @binding(2) var x3dSampler: sampler;

"""

private let x3dBuiltinKey: ShaderKey = "swiftx.x3d"

private let x3dBuiltinWGSL = """
struct X3DFullscreen {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn x3d_fullscreen(@builtin(vertex_index) index: u32) -> X3DFullscreen {
    var corners = array<vec2<f32>, 3>(vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
    let p = corners[index];
    var out: X3DFullscreen;
    out.position = vec4(p, 0.0, 1.0);
    out.uv = vec2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    return out;
}

@vertex
fn x3d_plane(@builtin(vertex_index) index: u32) -> X3DFullscreen {
    var corners = array<vec2<f32>, 6>(
        vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0),
        vec2(-1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0)
    );
    let c = corners[index];
    let local = vec4(c.x * x3dParams[0], c.y * x3dParams[1], 0.0, 1.0);
    let t = vec2(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
    var out: X3DFullscreen;
    out.position = x3d.viewProjection * x3d.model * local;
    out.uv = vec2(mix(x3dParams[2], x3dParams[4], t.x), mix(x3dParams[3], x3dParams[5], t.y));
    return out;
}

@group(1) @binding(0) var x3dSource: texture_2d<f32>;

@fragment
fn x3d_blit(in: X3DFullscreen) -> @location(0) vec4<f32> {
    return textureSample(x3dSource, x3dSampler, in.uv);
}

// A plane of XView content: texels that drew nothing are dropped, so only what is really there writes depth.
@fragment
fn x3d_plane_blit(in: X3DFullscreen) -> @location(0) vec4<f32> {
    let colour = textureSample(x3dSource, x3dSampler, in.uv);
    if (colour.a < 0.02) { discard; }
    return colour;
}

@fragment
fn x3d_fade(in: X3DFullscreen) -> @location(0) vec4<f32> {
    return vec4(0.0, 0.0, 0.0, clamp(x3dParams[0], 0.0, 1.0));
}
"""

private struct X3DCompositeShader: Shader {
    static let key: ShaderKey = "swiftx.x3dComposite"
    static let scope: ShaderScope = .layer
    func encode(into uniforms: inout ShaderUniforms) {}
}

struct X3DResourceRecord {
    enum Kind {
        case buffer(WGPUBuffer, byteCount: Int)
        case texture(WGPUTexture, WGPUTextureView, format: X3DFormat, width: UInt32, height: UInt32)
    }
    var kind: Kind
    var lastFrame: UInt32
    var contents: [Float]? = nil

    func release() {
        switch kind {
        case .buffer(let buffer, _):
            wgpuBufferRelease(buffer)
        case .texture(let texture, let view, _, _, _):
            wgpuTextureViewRelease(view)
            wgpuTextureRelease(texture)
        }
    }
}

private enum X3DBlendState: Equatable {
    case opaque, alpha, additive, fade

    init(_ blend: X3DBlend) {
        switch blend {
        case .opaque: self = .opaque
        case .alpha: self = .alpha
        case .additive: self = .additive
        }
    }
}

private struct X3DViewport {
    var view: WGPUTextureView
    var format: WGPUTextureFormat
    var x: UInt32, y: UInt32, width: UInt32, height: UInt32
    var attachmentWidth: UInt32, attachmentHeight: UInt32
    var depth: WGPUTextureView?
    /// Where shaders think the drawing is (origin) and how big it is (resolution), when that differs from the viewport
    /// because the drawing overflows the target.
    var exactOrigin: SIMD2<Float>?
    var exactSize: SIMD2<Float>?
}

extension WGPURenderer {
    /// Supplies the WGSL behind an X3D shader key. Replacing a source
    /// rebuilds its pipelines on next use.
    public func registerX3DShader(_ key: ShaderKey, source: String) {
        x3dShaderSources[key] = source
        x3dFailures = x3dFailures.filter { !$0.hasPrefix(key.rawValue + "|") && $0 != key.rawValue }
        if let module = x3dModules.removeValue(forKey: key) { wgpuShaderModuleRelease(module) }
        for (pipelineKey, pipeline) in x3dPipelines where pipelineKey.hasPrefix(key.rawValue + "|") {
            wgpuRenderPipelineRelease(pipeline)
            x3dPipelines[pipelineKey] = nil
        }
        for (pipelineKey, pipeline) in x3dComputePipelines where pipelineKey.hasPrefix(key.rawValue + "|") {
            wgpuComputePipelineRelease(pipeline)
            x3dComputePipelines[pipelineKey] = nil
        }
    }

    func advanceX3DClock(_ time: Float) {
        if let last = x3dLastTime {
            x3dDeltaTime = min(max(0, time - last), 0.1)
            x3dFrameIndex &+= 1
        } else {
            x3dDeltaTime = 0
        }
        x3dLastTime = time
        x3dTime = time
        for (id, record) in x3dResources where x3dFrameIndex &- record.lastFrame > 120 {
            record.release()
            x3dResources[id] = nil
        }
    }

    func releaseX3DResources() {
        for pipeline in x3dPipelines.values { wgpuRenderPipelineRelease(pipeline) }
        for pipeline in x3dComputePipelines.values { wgpuComputePipelineRelease(pipeline) }
        for module in x3dModules.values { wgpuShaderModuleRelease(module) }
        for layout in x3dPipelineLayouts.values { wgpuPipelineLayoutRelease(layout) }
        for layout in x3dGroupLayouts.values { wgpuBindGroupLayoutRelease(layout) }
        for record in x3dResources.values { record.release() }
        if let x3dSampler { wgpuSamplerRelease(x3dSampler) }
        releaseX3DDepthTargets()
        for target in x3dPlaneTargets {
            wgpuTextureViewRelease(target.view)
            wgpuTextureRelease(target.texture)
        }
        x3dPlaneTargets.removeAll()
        x3dPipelines.removeAll()
        x3dComputePipelines.removeAll()
        x3dModules.removeAll()
        x3dPipelineLayouts.removeAll()
        x3dGroupLayouts.removeAll()
        x3dResources.removeAll()
        x3dSampler = nil
    }

    // MARK: graph

    func encodeX3D(_ x3d: CompiledX3D, parent: WGPUTextureView, encoder: WGPUCommandEncoder, depth: Int) {
        guard let target = ensureShaderLayerTarget(at: depth) else { return }
        let x = min(x3d.rect.x, configuredWidth), y = min(x3d.rect.y, configuredHeight)
        let output = X3DViewport(view: target.view, format: surfaceFormat, x: x, y: y,
                                 width: min(x3d.rect.width, configuredWidth - x),
                                 height: min(x3d.rect.height, configuredHeight - y),
                                 attachmentWidth: configuredWidth, attachmentHeight: configuredHeight,
                                 exactOrigin: x3d.exactRect.map { SIMD2($0.x, $0.y) },
                                 exactSize: x3d.exactRect.map { SIMD2($0.z, $0.w) })
        guard output.width > 0, output.height > 0 else { return }
        for resource in x3d.graph.resources {
            ensureX3DResource(resource, outputWidth: output.width, outputHeight: output.height)
        }
        beginX3DPass(target.view, load: .clear(SIMD4(0, 0, 0, 0)), depth: nil, encoder: encoder).map(endX3DPass)

        var viewIndex = 0
        var planeIndex = 0
        for pass in x3d.graph.passes {
            switch pass {
            case .compute(let compute):
                encodeX3DCompute(compute, width: output.width, height: output.height, encoder: encoder)
            case .render(let render):
                var viewport: X3DViewport?
                switch render.target {
                case .output: viewport = output
                case .texture(let id): viewport = x3dTextureViewport(id)
                }
                if render.depth, let attached = viewport {
                    viewport?.depth = x3dDepthView(width: attached.attachmentWidth, height: attached.attachmentHeight)
                    if let depthView = viewport?.depth, case .output = render.target {
                        x3dRecordDepth(depthView, camera: render.items.lazy.compactMap { item -> X3DCamera? in
                            switch item {
                            case .draw(let draw): return draw.camera
                            case .plane(_, _, let camera, _): return camera
                            default: return nil
                            }
                        }.first)
                    }
                }
                guard let viewport else {
                    for item in render.items {
                        switch item {
                        case .view: viewIndex += 1
                        case .plane: planeIndex += 1
                        case .draw, .blit: break
                        }
                    }
                    continue
                }
                var active = beginX3DPass(viewport.view, load: render.load, depth: viewport.depth, encoder: encoder)
                if case .fade(let amount) = render.load, let active {
                    let fade = X3DDraw(shader: x3dBuiltinKey, vertexEntry: "x3d_fullscreen", fragmentEntry: "x3d_fade",
                                       vertexCount: 3, uniforms: [amount])
                    encodeX3DDraw(fade, blend: .fade, viewport: viewport, pass: active)
                }
                for item in render.items {
                    switch item {
                    case .draw(let draw):
                        if let active { encodeX3DDraw(draw, blend: X3DBlendState(draw.blend), viewport: viewport, pass: active) }
                    case .blit(let id, let blend):
                        let blit = X3DDraw(shader: x3dBuiltinKey, vertexEntry: "x3d_fullscreen", fragmentEntry: "x3d_blit",
                                           vertexCount: 3, bindings: [X3DBinding(resource: id, access: .read)])
                        if let active { encodeX3DDraw(blit, blend: X3DBlendState(blend), viewport: viewport, pass: active) }
                    case .view:
                        defer { viewIndex += 1 }
                        guard case .output = render.target, x3d.views.indices.contains(viewIndex) else { continue }
                        active.map(endX3DPass)
                        active = nil
                        let frame = x3d.views[viewIndex]
                        drawScene(frame, geometry: makeTransientGeometryBuffers(for: frame), into: target.view,
                                  encoder: encoder, clear: nil, time: x3dTime, depth: depth + 1)
                        active = beginX3DPass(viewport.view, load: .load, depth: viewport.depth,
                                              clearDepth: false, encoder: encoder)
                    case .plane(let size, _, let camera, let model):
                        defer { planeIndex += 1 }
                        guard x3d.planes.indices.contains(planeIndex),
                              let planeTarget = x3dPlaneTarget(planeIndex) else { continue }
                        active.map(endX3DPass)
                        active = nil
                        let plane = x3d.planes[planeIndex]
                        drawScene(plane.frame, geometry: makeTransientGeometryBuffers(for: plane.frame),
                                  into: planeTarget.view, encoder: encoder, clear: RenderColor(0, 0, 0, 0),
                                  time: x3dTime, depth: depth + 1)
                        active = beginX3DPass(viewport.view, load: .load, depth: viewport.depth,
                                              clearDepth: false, encoder: encoder)
                        let id = X3DResourceID(scope: .min, name: "plane\(planeIndex)")
                        x3dResources[id] = X3DResourceRecord(
                            kind: .texture(planeTarget.texture, planeTarget.view, format: .rgba8Unorm,
                                           width: planeTarget.width, height: planeTarget.height),
                            lastFrame: x3dFrameIndex
                        )
                        let draw = X3DDraw(
                            shader: x3dBuiltinKey, vertexEntry: "x3d_plane", fragmentEntry: "x3d_plane_blit",
                            vertexCount: 6, bindings: [X3DBinding(resource: id, access: .read)],
                            uniforms: [size.width / 200, size.height / 200,
                                       plane.uv.x, plane.uv.y, plane.uv.z, plane.uv.w],
                            camera: camera, model: model
                        )
                        if let active { encodeX3DDraw(draw, blend: .alpha, viewport: viewport, pass: active) }
                        x3dResources[id] = nil
                    }
                }
                active.map(endX3DPass)
            }
        }
        runLayerPost(into: parent, sourceView: target.view, time: x3dTime,
                     layer: CompiledShaderLayer(rect: x3d.rect, shader: X3DCompositeShader().erased(),
                                                frame: CompiledFrame()),
                     encoder: encoder)
    }

    // MARK: resources

    private func ensureX3DResource(_ resource: X3DResource, outputWidth: UInt32, outputHeight: UInt32) {
        let id = resource.id
        if var record = x3dResources[id], x3dRecord(record, matches: resource, outputWidth, outputHeight) {
            record.lastFrame = x3dFrameIndex
            x3dResources[id] = record
            return
        }
        x3dResources.removeValue(forKey: id)?.release()
        switch resource {
        case .buffer(_, let byteCount, let contents):
            let size = max(16, (byteCount + 3) / 4 * 4)
            var descriptor = WGPUBufferDescriptor()
            descriptor.usage = WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst
            descriptor.size = UInt64(size)
            guard let buffer = wgpuDeviceCreateBuffer(device, &descriptor) else { return }
            if let contents, !contents.isEmpty {
                contents.prefix(size / 4).withUnsafeBytes {
                    wgpuQueueWriteBuffer(queue, buffer, 0, $0.baseAddress, $0.count)
                }
            }
            x3dResources[id] = X3DResourceRecord(kind: .buffer(buffer, byteCount: byteCount),
                                                 lastFrame: x3dFrameIndex, contents: contents)
        case .texture(_, let format, let size):
            let (width, height) = x3dTextureSize(size, outputWidth, outputHeight)
            var descriptor = WGPUTextureDescriptor()
            descriptor.usage = WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_TextureBinding
                | WGPUTextureUsage_StorageBinding
            descriptor.dimension = WGPUTextureDimension_2D
            descriptor.size = WGPUExtent3D(width: width, height: height, depthOrArrayLayers: 1)
            descriptor.format = Self.textureFormat(format)
            descriptor.mipLevelCount = 1
            descriptor.sampleCount = 1
            guard let texture = wgpuDeviceCreateTexture(device, &descriptor) else { return }
            guard let view = wgpuTextureCreateView(texture, nil) else {
                wgpuTextureRelease(texture)
                return
            }
            x3dResources[id] = X3DResourceRecord(
                kind: .texture(texture, view, format: format, width: width, height: height),
                lastFrame: x3dFrameIndex
            )
        }
    }

    private func x3dRecord(_ record: X3DResourceRecord, matches resource: X3DResource,
                           _ outputWidth: UInt32, _ outputHeight: UInt32) -> Bool {
        switch (record.kind, resource) {
        case (.buffer(_, let have), .buffer(_, let want, let contents)):
            return have == want && record.contents == contents
        case (.texture(_, _, let haveFormat, let width, let height), .texture(_, let format, let size)):
            let wanted = x3dTextureSize(size, outputWidth, outputHeight)
            return haveFormat == format && width == wanted.0 && height == wanted.1
        default:
            return false
        }
    }

    private func x3dTextureSize(_ size: X3DSize, _ outputWidth: UInt32, _ outputHeight: UInt32) -> (UInt32, UInt32) {
        switch size {
        case .target: return (outputWidth, outputHeight)
        case .scaled(let factor):
            return (UInt32(max(1, (Float(outputWidth) * factor).rounded())),
                    UInt32(max(1, (Float(outputHeight) * factor).rounded())))
        case .fixed(let width, let height): return (UInt32(max(1, width)), UInt32(max(1, height)))
        }
    }

    private func x3dTextureViewport(_ id: X3DResourceID) -> X3DViewport? {
        guard case .texture(_, let view, let format, let width, let height)? = x3dResources[id]?.kind else {
            rendererLog("[X3D] pass target \(id.name) is not a declared texture")
            return nil
        }
        return X3DViewport(view: view, format: Self.textureFormat(format), x: 0, y: 0, width: width, height: height,
                           attachmentWidth: width, attachmentHeight: height)
    }

    private static func textureFormat(_ format: X3DFormat) -> WGPUTextureFormat {
        switch format {
        case .rgba8Unorm: return WGPUTextureFormat_RGBA8Unorm
        case .rgba16Float: return WGPUTextureFormat_RGBA16Float
        case .r32Float: return WGPUTextureFormat_R32Float
        }
    }

    // MARK: passes

    private func x3dDepthView(width: UInt32, height: UInt32) -> WGPUTextureView? {
        let key = "\(width)x\(height)"
        if let target = x3dDepthTargets[key] { return target.view }
        if x3dDepthTargets.count >= 4 { releaseX3DDepthTargets() }
        var descriptor = WGPUTextureDescriptor()
        descriptor.usage = WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_TextureBinding
        descriptor.dimension = WGPUTextureDimension_2D
        descriptor.size = WGPUExtent3D(width: width, height: height, depthOrArrayLayers: 1)
        descriptor.format = WGPUTextureFormat_Depth32Float
        descriptor.mipLevelCount = 1
        descriptor.sampleCount = 1
        guard let texture = wgpuDeviceCreateTexture(device, &descriptor) else { return nil }
        guard let view = wgpuTextureCreateView(texture, nil) else {
            wgpuTextureRelease(texture)
            return nil
        }
        x3dDepthTargets[key] = (texture, view)
        return view
    }

    private func x3dPlaneTarget(_ index: Int) -> (texture: WGPUTexture, view: WGPUTextureView,
                                                  width: UInt32, height: UInt32)? {
        if x3dPlaneTargets.indices.contains(index) {
            let existing = x3dPlaneTargets[index]
            if existing.width == configuredWidth && existing.height == configuredHeight { return existing }
            wgpuTextureViewRelease(existing.view)
            wgpuTextureRelease(existing.texture)
        }
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
        let target = (texture: texture, view: view, width: configuredWidth, height: configuredHeight)
        if x3dPlaneTargets.indices.contains(index) {
            x3dPlaneTargets[index] = target
        } else {
            x3dPlaneTargets.append(target)
        }
        return target
    }

    /// Remembers the depth a pass left (it is cleared by the next pass that draws with depth) and the camera it was drawn with.
    func x3dRecordDepth(_ view: WGPUTextureView, camera: X3DCamera?) {
        let near = camera?.near ?? 0.05, far = camera?.far ?? 100
        let focus = camera.map { camera -> Float in
            let offset = camera.position - camera.target
            return (offset.x * offset.x + offset.y * offset.y + offset.z * offset.z).squareRoot()
        } ?? 0
        x3dDepthInfo = (view, near * far / (far - near), far / (far - near), focus)
    }

    func releaseX3DDepthTargets() {
        for target in x3dDepthTargets.values {
            wgpuTextureViewRelease(target.view)
            wgpuTextureRelease(target.texture)
        }
        x3dDepthTargets.removeAll()
    }

    private func beginX3DPass(_ view: WGPUTextureView, load: X3DLoad, depth: WGPUTextureView?,
                              clearDepth: Bool = true, encoder: WGPUCommandEncoder) -> WGPURenderPassEncoder? {
        var attachment = WGPURenderPassColorAttachment()
        attachment.view = view
        attachment.depthSlice = UInt32.max
        attachment.storeOp = WGPUStoreOp_Store
        switch load {
        case .clear(let color):
            attachment.loadOp = WGPULoadOp_Clear
            attachment.clearValue = WGPUColor(r: Double(color.x), g: Double(color.y),
                                              b: Double(color.z), a: Double(color.w))
        case .load, .fade:
            attachment.loadOp = WGPULoadOp_Load
        }
        var depthAttachment = WGPURenderPassDepthStencilAttachment()
        depthAttachment.view = depth
        depthAttachment.depthLoadOp = clearDepth ? WGPULoadOp_Clear : WGPULoadOp_Load
        depthAttachment.depthStoreOp = WGPUStoreOp_Store
        depthAttachment.depthClearValue = 1
        return withUnsafePointer(to: &attachment) { pointer in
            withUnsafePointer(to: &depthAttachment) { depthPointer in
                var descriptor = WGPURenderPassDescriptor()
                descriptor.colorAttachmentCount = 1
                descriptor.colorAttachments = pointer
                descriptor.depthStencilAttachment = depth == nil ? nil : depthPointer
                return wgpuCommandEncoderBeginRenderPass(encoder, &descriptor)
            }
        }
    }

    private func endX3DPass(_ pass: WGPURenderPassEncoder) {
        wgpuRenderPassEncoderEnd(pass)
        wgpuRenderPassEncoderRelease(pass)
    }

    private func encodeX3DDraw(_ draw: X3DDraw, blend: X3DBlendState, viewport: X3DViewport,
                               pass: WGPURenderPassEncoder) {
        guard let layout = x3dLayout(for: draw.bindings, compute: false),
              let pipeline = x3dRenderPipeline(for: draw, blend: blend, format: viewport.format,
                                               depth: viewport.depth != nil,
                                               signature: layout.signature, layout: layout.pipeline),
              let frameGroup = x3dFrameGroup(width: viewport.width, height: viewport.height,
                                             x: viewport.x, y: viewport.y,
                                             exactOrigin: viewport.exactOrigin, exactSize: viewport.exactSize, params: draw.uniforms,
                                             camera: draw.camera, model: draw.model) else { return }
        wgpuRenderPassEncoderSetPipeline(pass, pipeline)
        wgpuRenderPassEncoderSetBindGroup(pass, 0, frameGroup, 0, nil)
        if let resourceLayout = layout.resources {
            guard let group = x3dResourceGroup(draw.bindings, layout: resourceLayout) else { return }
            wgpuRenderPassEncoderSetBindGroup(pass, 1, group, 0, nil)
        }
        wgpuRenderPassEncoderSetViewport(pass, Float(viewport.x), Float(viewport.y),
                                         Float(viewport.width), Float(viewport.height), 0, 1)
        wgpuRenderPassEncoderSetScissorRect(pass, viewport.x, viewport.y, viewport.width, viewport.height)
        wgpuRenderPassEncoderDraw(pass, UInt32(draw.vertexCount), UInt32(draw.instanceCount), 0, 0)
    }

    private func encodeX3DCompute(_ compute: X3DCompute, width: UInt32, height: UInt32,
                                  encoder: WGPUCommandEncoder) {
        guard compute.threads > 0,
              let layout = x3dLayout(for: compute.bindings, compute: true),
              let pipeline = x3dComputePipeline(for: compute, signature: layout.signature, layout: layout.pipeline),
              let frameGroup = x3dFrameGroup(width: width, height: height, x: 0, y: 0, params: compute.uniforms,
                                             camera: nil, model: .identity)
        else { return }
        var resourceGroup: WGPUBindGroup?
        if let resourceLayout = layout.resources {
            guard let group = x3dResourceGroup(compute.bindings, layout: resourceLayout) else { return }
            resourceGroup = group
        }
        guard let pass = wgpuCommandEncoderBeginComputePass(encoder, nil) else { return }
        wgpuComputePassEncoderSetPipeline(pass, pipeline)
        wgpuComputePassEncoderSetBindGroup(pass, 0, frameGroup, 0, nil)
        if let resourceGroup { wgpuComputePassEncoderSetBindGroup(pass, 1, resourceGroup, 0, nil) }
        wgpuComputePassEncoderDispatchWorkgroups(pass, UInt32((compute.threads + 63) / 64), 1, 1)
        wgpuComputePassEncoderEnd(pass)
        wgpuComputePassEncoderRelease(pass)
    }

    // MARK: bind groups

    private func x3dFrameGroup(width: UInt32, height: UInt32, x: UInt32, y: UInt32,
                               exactOrigin: SIMD2<Float>? = nil, exactSize: SIMD2<Float>? = nil,
                               params: [Float], camera: X3DCamera?, model: X3DTransform) -> WGPUBindGroup? {
        guard let layout = x3dFrameLayout(), let sampler = ensureX3DSampler() else { return nil }
        // `resolution` and `origin` describe the drawing as laid out; the camera's aspect follows the viewport actually drawn.
        var frame: [UInt32] = [
            (exactSize?.x ?? Float(width)).bitPattern, (exactSize?.y ?? Float(height)).bitPattern,
            (exactOrigin?.x ?? Float(x)).bitPattern, (exactOrigin?.y ?? Float(y)).bitPattern,
            x3dTime.bitPattern, x3dDeltaTime.bitPattern,
            x3dFrameIndex, 0,
        ]
        let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let aspect = Float(width) / Float(max(height, 1))
        frame += (camera?.viewProjection(aspect: aspect, time: x3dTime) ?? identity).map(\.bitPattern)
        let eye = camera?.eye(at: x3dTime) ?? .zero
        frame += [eye.x.bitPattern, eye.y.bitPattern, eye.z.bitPattern, Float(1).bitPattern]
        frame += model.matrix.map(\.bitPattern)
        var values = params
        while values.count < 4 { values.append(0) }
        guard let frameBuffer = makeX3DTransientBuffer(&frame, usage: WGPUBufferUsage_Uniform),
              let paramsBuffer = makeX3DTransientBuffer(&values, usage: WGPUBufferUsage_Storage) else { return nil }
        var entries = [WGPUBindGroupEntry(), WGPUBindGroupEntry(), WGPUBindGroupEntry()]
        entries[0].binding = 0; entries[0].buffer = frameBuffer; entries[0].size = UInt64(frame.count * 4)
        entries[1].binding = 1; entries[1].buffer = paramsBuffer; entries[1].size = UInt64(values.count * 4)
        entries[2].binding = 2; entries[2].sampler = sampler
        return makeX3DBindGroup(entries, layout: layout)
    }

    private func x3dResourceGroup(_ bindings: [X3DBinding], layout: WGPUBindGroupLayout) -> WGPUBindGroup? {
        var entries: [WGPUBindGroupEntry] = []
        for (index, binding) in bindings.enumerated() {
            guard let record = x3dResources[binding.resource] else {
                rendererLog("[X3D] bound resource \(binding.resource.name) is not declared")
                return nil
            }
            var entry = WGPUBindGroupEntry()
            entry.binding = UInt32(index)
            switch record.kind {
            case .buffer(let buffer, let byteCount):
                entry.buffer = buffer
                entry.size = UInt64(max(16, (byteCount + 3) / 4 * 4))
            case .texture(_, let view, _, _, _):
                entry.textureView = view
            }
            entries.append(entry)
        }
        return makeX3DBindGroup(entries, layout: layout)
    }

    private func makeX3DBindGroup(_ entries: [WGPUBindGroupEntry], layout: WGPUBindGroupLayout) -> WGPUBindGroup? {
        let group = entries.withUnsafeBufferPointer { pointer -> WGPUBindGroup? in
            var descriptor = WGPUBindGroupDescriptor()
            descriptor.layout = layout
            descriptor.entryCount = pointer.count
            descriptor.entries = pointer.baseAddress
            return wgpuDeviceCreateBindGroup(device, &descriptor)
        }
        if let group { transientPostBindGroups.append(group) }
        return group
    }

    private func makeX3DTransientBuffer<T>(_ values: inout [T], usage: WGPUBufferUsage) -> WGPUBuffer? {
        let size = values.count * MemoryLayout<T>.stride
        var descriptor = WGPUBufferDescriptor()
        descriptor.usage = usage | WGPUBufferUsage_CopyDst
        descriptor.size = UInt64(size)
        guard let buffer = wgpuDeviceCreateBuffer(device, &descriptor) else { return nil }
        values.withUnsafeBytes { wgpuQueueWriteBuffer(queue, buffer, 0, $0.baseAddress, size) }
        transientPostUniformBuffers.append(buffer)
        return buffer
    }

    private func ensureX3DSampler() -> WGPUSampler? {
        if let x3dSampler { return x3dSampler }
        var descriptor = WGPUSamplerDescriptor()
        descriptor.addressModeU = WGPUAddressMode_ClampToEdge
        descriptor.addressModeV = WGPUAddressMode_ClampToEdge
        descriptor.addressModeW = WGPUAddressMode_ClampToEdge
        descriptor.magFilter = WGPUFilterMode_Linear
        descriptor.minFilter = WGPUFilterMode_Linear
        descriptor.mipmapFilter = WGPUMipmapFilterMode_Nearest
        descriptor.lodMaxClamp = 32
        descriptor.maxAnisotropy = 1
        x3dSampler = wgpuDeviceCreateSampler(device, &descriptor)
        return x3dSampler
    }

    // MARK: layouts

    private func x3dFrameLayout() -> WGPUBindGroupLayout? {
        if let layout = x3dGroupLayouts["frame"] { return layout }
        var entries = [WGPUBindGroupLayoutEntry(), WGPUBindGroupLayoutEntry(), WGPUBindGroupLayoutEntry()]
        let stages = WGPUShaderStage_Vertex | WGPUShaderStage_Fragment | WGPUShaderStage_Compute
        entries[0].binding = 0
        entries[0].visibility = stages
        entries[0].buffer.type = WGPUBufferBindingType_Uniform
        entries[1].binding = 1
        entries[1].visibility = stages
        entries[1].buffer.type = WGPUBufferBindingType_ReadOnlyStorage
        entries[2].binding = 2
        entries[2].visibility = stages
        entries[2].sampler.type = WGPUSamplerBindingType_Filtering
        let layout = makeX3DGroupLayout(entries)
        x3dGroupLayouts["frame"] = layout
        return layout
    }

    private func makeX3DGroupLayout(_ entries: [WGPUBindGroupLayoutEntry]) -> WGPUBindGroupLayout? {
        entries.withUnsafeBufferPointer { pointer in
            var descriptor = WGPUBindGroupLayoutDescriptor()
            descriptor.entryCount = pointer.count
            descriptor.entries = pointer.baseAddress
            return wgpuDeviceCreateBindGroupLayout(device, &descriptor)
        }
    }

    private func x3dLayout(for bindings: [X3DBinding], compute: Bool)
        -> (signature: String, pipeline: WGPUPipelineLayout, resources: WGPUBindGroupLayout?)? {
        var signature = compute ? "c" : "r"
        var entries: [WGPUBindGroupLayoutEntry] = []
        for (index, binding) in bindings.enumerated() {
            guard let record = x3dResources[binding.resource] else {
                rendererLog("[X3D] bound resource \(binding.resource.name) is not declared")
                return nil
            }
            var entry = WGPUBindGroupLayoutEntry()
            entry.binding = UInt32(index)
            switch (record.kind, binding.access) {
            case (.buffer, .read):
                signature += "|br"
                entry.visibility = compute ? WGPUShaderStage_Compute : WGPUShaderStage_Vertex | WGPUShaderStage_Fragment
                entry.buffer.type = WGPUBufferBindingType_ReadOnlyStorage
            case (.buffer, .readWrite):
                signature += "|bw"
                entry.visibility = compute ? WGPUShaderStage_Compute : WGPUShaderStage_Fragment
                entry.buffer.type = WGPUBufferBindingType_Storage
            case (.texture(_, _, let format, _, _), .read):
                signature += "|tr\(format.rawValue)"
                entry.visibility = compute ? WGPUShaderStage_Compute : WGPUShaderStage_Vertex | WGPUShaderStage_Fragment
                entry.texture.sampleType = format == .r32Float
                    ? WGPUTextureSampleType_UnfilterableFloat : WGPUTextureSampleType_Float
                entry.texture.viewDimension = WGPUTextureViewDimension_2D
            case (.texture(_, _, let format, _, _), .readWrite):
                signature += "|tw\(format.rawValue)"
                entry.visibility = compute ? WGPUShaderStage_Compute : WGPUShaderStage_Fragment
                entry.storageTexture.access = WGPUStorageTextureAccess_WriteOnly
                entry.storageTexture.format = Self.textureFormat(format)
                entry.storageTexture.viewDimension = WGPUTextureViewDimension_2D
            }
            entries.append(entry)
        }
        guard let frame = x3dFrameLayout() else { return nil }
        var resources: WGPUBindGroupLayout?
        if !entries.isEmpty {
            if let cached = x3dGroupLayouts[signature] {
                resources = cached
            } else {
                guard let made = makeX3DGroupLayout(entries) else { return nil }
                x3dGroupLayouts[signature] = made
                resources = made
            }
        }
        if let pipeline = x3dPipelineLayouts[signature] { return (signature, pipeline, resources) }
        let groups: [WGPUBindGroupLayout?] = resources.map { [frame, $0] } ?? [frame]
        let pipeline = groups.withUnsafeBufferPointer { pointer -> WGPUPipelineLayout? in
            var descriptor = WGPUPipelineLayoutDescriptor()
            descriptor.bindGroupLayoutCount = pointer.count
            descriptor.bindGroupLayouts = pointer.baseAddress
            return wgpuDeviceCreatePipelineLayout(device, &descriptor)
        }
        guard let pipeline else { return nil }
        x3dPipelineLayouts[signature] = pipeline
        return (signature, pipeline, resources)
    }

    // MARK: pipelines

    private func x3dModule(for key: ShaderKey) -> WGPUShaderModule? {
        if let module = x3dModules[key] { return module }
        let source = key == x3dBuiltinKey ? x3dBuiltinWGSL : x3dShaderSources[key]
        guard let source else {
            rendererLog("[X3D] no shader registered for \(key.rawValue)")
            return nil
        }
        guard !x3dFailures.contains(key.rawValue) else { return nil }
        guard let module = x3dChecked(key.rawValue, release: { (module: WGPUShaderModule) in wgpuShaderModuleRelease(module) }, {
            Self.makeShaderModule(device: device, wgsl: x3dPreludeWGSL + source)
        }) else { return nil }
        x3dModules[key] = module
        return module
    }

    private func x3dComputePipeline(for compute: X3DCompute, signature: String,
                                    layout: WGPUPipelineLayout) -> WGPUComputePipeline? {
        let key = "\(compute.shader.rawValue)|\(compute.entry)|\(signature)"
        if let pipeline = x3dComputePipelines[key] { return pipeline }
        guard !x3dFailures.contains(key), let module = x3dModule(for: compute.shader) else { return nil }
        let pipeline = x3dChecked(key, release: { (pipeline: WGPUComputePipeline) in wgpuComputePipelineRelease(pipeline) }) { withWGPUString(compute.entry) { entry -> WGPUComputePipeline? in
            var descriptor = WGPUComputePipelineDescriptor()
            descriptor.layout = layout
            descriptor.compute.module = module
            descriptor.compute.entryPoint = entry
            return wgpuDeviceCreateComputePipeline(device, &descriptor)
        } }
        if let pipeline { x3dComputePipelines[key] = pipeline }
        return pipeline
    }

    private func x3dRenderPipeline(for draw: X3DDraw, blend mode: X3DBlendState, format: WGPUTextureFormat,
                                   depth: Bool, signature: String,
                                   layout: WGPUPipelineLayout) -> WGPURenderPipeline? {
        let key = "\(draw.shader.rawValue)|\(draw.vertexEntry)|\(draw.fragmentEntry)|\(draw.topology)"
            + "|\(mode)|\(format.rawValue)|\(depth)|\(signature)"
        if let pipeline = x3dPipelines[key] { return pipeline }
        guard !x3dFailures.contains(key), let module = x3dModule(for: draw.shader) else { return nil }
        let pipeline = x3dChecked(key, release: { (pipeline: WGPURenderPipeline) in wgpuRenderPipelineRelease(pipeline) }) { withWGPUString(draw.vertexEntry) { vertexEntry in
            withWGPUString(draw.fragmentEntry) { fragmentEntry -> WGPURenderPipeline? in
                var blend = WGPUBlendState()
                blend.color.operation = WGPUBlendOperation_Add
                blend.alpha.operation = WGPUBlendOperation_Add
                switch mode {
                case .opaque, .alpha:
                    blend.color.srcFactor = WGPUBlendFactor_One
                    blend.alpha.srcFactor = WGPUBlendFactor_One
                    blend.color.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha
                    blend.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha
                case .additive:
                    blend.color.srcFactor = WGPUBlendFactor_One
                    blend.alpha.srcFactor = WGPUBlendFactor_One
                    blend.color.dstFactor = WGPUBlendFactor_One
                    blend.alpha.dstFactor = WGPUBlendFactor_One
                case .fade:
                    blend.color.srcFactor = WGPUBlendFactor_Zero
                    blend.alpha.srcFactor = WGPUBlendFactor_Zero
                    blend.color.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha
                    blend.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha
                }
                return withUnsafePointer(to: &blend) { blendPointer in
                    var target = WGPUColorTargetState()
                    target.format = format
                    target.blend = mode == .opaque ? nil : blendPointer
                    target.writeMask = WGPUColorWriteMask_All
                    return withUnsafePointer(to: &target) { targetPointer in
                        var fragment = WGPUFragmentState()
                        fragment.module = module
                        fragment.entryPoint = fragmentEntry
                        fragment.targetCount = 1
                        fragment.targets = targetPointer
                        return withUnsafePointer(to: &fragment) { fragmentPointer in
                            var descriptor = WGPURenderPipelineDescriptor()
                            descriptor.layout = layout
                            descriptor.vertex.module = module
                            descriptor.vertex.entryPoint = vertexEntry
                            descriptor.vertex.bufferCount = 0
                            descriptor.primitive.topology = Self.topology(draw.topology)
                            descriptor.primitive.frontFace = WGPUFrontFace_CCW
                            descriptor.primitive.cullMode = WGPUCullMode_None
                            descriptor.multisample.count = 1
                            descriptor.multisample.mask = UInt32.max
                            descriptor.fragment = fragmentPointer
                            guard depth else { return wgpuDeviceCreateRenderPipeline(device, &descriptor) }
                            var depthState = WGPUDepthStencilState()
                            depthState.format = WGPUTextureFormat_Depth32Float
                            let overlay = draw.vertexEntry == "x3d_fullscreen"
                            depthState.depthWriteEnabled = (mode == .opaque || draw.fragmentEntry == "x3d_plane_blit") && !overlay
                                ? WGPUOptionalBool_True : WGPUOptionalBool_False
                            depthState.depthCompare = overlay ? WGPUCompareFunction_Always : WGPUCompareFunction_Less
                            for face in [\WGPUDepthStencilState.stencilFront, \WGPUDepthStencilState.stencilBack] {
                                depthState[keyPath: face].compare = WGPUCompareFunction_Always
                                depthState[keyPath: face].failOp = WGPUStencilOperation_Keep
                                depthState[keyPath: face].depthFailOp = WGPUStencilOperation_Keep
                                depthState[keyPath: face].passOp = WGPUStencilOperation_Keep
                            }
                            return withUnsafePointer(to: &depthState) { depthPointer in
                                descriptor.depthStencil = depthPointer
                                return wgpuDeviceCreateRenderPipeline(device, &descriptor)
                            }
                        }
                    }
                }
            }
        } }
        if let pipeline { x3dPipelines[key] = pipeline }
        return pipeline
    }

    /// Runs `make` inside a validation error scope. A failure is logged once
    /// and remembered so a broken shader never reaches a submit.
    private func x3dChecked<T>(_ key: String, release: (T) -> Void, _ make: () -> T?) -> T? {
        wgpuDevicePushErrorScope(device, WGPUErrorFilter_Validation)
        let value = make()
        let box = X3DScopeBox()
        var info = WGPUPopErrorScopeCallbackInfo()
        info.mode = WGPUCallbackMode_AllowProcessEvents
        info.callback = { status, type, message, userdata, _ in
            let box = Unmanaged<X3DScopeBox>.fromOpaque(userdata!).takeUnretainedValue()
            box.failed = status != WGPUPopErrorScopeStatus_Success || type != WGPUErrorType_NoError
            if let data = message.data, message.length > 0 {
                box.message = String(decoding: UnsafeRawBufferPointer(start: data, count: message.length), as: UTF8.self)
            }
            box.done = true
        }
        info.userdata1 = Unmanaged.passUnretained(box).toOpaque()
        _ = wgpuDevicePopErrorScope(device, info)
        var spins = 0
        while !box.done && spins < 10_000 {
            wgpuInstanceProcessEvents(instance)
            spins += 1
        }
        guard box.done, !box.failed, let value else {
            rendererLog("[X3D] \(key) failed: \(box.message)")
            x3dFailures.insert(key)
            if let value { release(value) }
            return nil
        }
        return value
    }

    private static func topology(_ topology: X3DTopology) -> WGPUPrimitiveTopology {
        switch topology {
        case .triangleList: return WGPUPrimitiveTopology_TriangleList
        case .triangleStrip: return WGPUPrimitiveTopology_TriangleStrip
        case .lineList: return WGPUPrimitiveTopology_LineList
        case .pointList: return WGPUPrimitiveTopology_PointList
        }
    }
}

private final class X3DScopeBox {
    var done = false
    var failed = false
    var message = ""
}
