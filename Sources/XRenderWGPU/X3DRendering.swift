import CWGPU
import XRender
import XShader

/// Prepended to every X3D shader. `origin`/`resolution` are the hosting
/// view's rect in framebuffer pixels; `@builtin(position)` stays in
/// framebuffer pixels, so `position.xy - x3d.origin` is view-local.
let x3dPreludeWGSL = """
struct X3DFrame {
    resolution: vec2<f32>,
    origin: vec2<f32>,
    time: f32,
    dt: f32,
    frame: u32,
    pad: u32,
};
@group(0) @binding(0) var<uniform> x3d: X3DFrame;
@group(0) @binding(1) var<storage, read> x3dParams: array<f32>;

"""

private struct X3DCompositeShader: Shader {
    static let key: ShaderKey = "swiftx.x3dComposite"
    static let scope: ShaderScope = .layer
    func encode(into uniforms: inout ShaderUniforms) {}
}

extension WGPURenderer {
    /// Supplies the WGSL behind an X3D shader key. Replacing a source
    /// rebuilds its pipelines on next use.
    public func registerX3DShader(_ key: ShaderKey, source: String) {
        x3dShaderSources[key] = source
        if let module = x3dModules.removeValue(forKey: key) { wgpuShaderModuleRelease(module) }
        for (pipelineKey, pipeline) in x3dPipelines where pipelineKey.hasPrefix(key.rawValue + "|") {
            wgpuRenderPipelineRelease(pipeline)
            x3dPipelines[pipelineKey] = nil
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
    }

    func releaseX3DResources() {
        for pipeline in x3dPipelines.values { wgpuRenderPipelineRelease(pipeline) }
        for module in x3dModules.values { wgpuShaderModuleRelease(module) }
        x3dPipelines.removeAll()
        x3dModules.removeAll()
        if let x3dPipelineLayout { wgpuPipelineLayoutRelease(x3dPipelineLayout) }
        if let x3dGroupLayout { wgpuBindGroupLayoutRelease(x3dGroupLayout) }
        x3dPipelineLayout = nil
        x3dGroupLayout = nil
    }

    func encodeX3D(_ x3d: CompiledX3D, parent: WGPUTextureView, encoder: WGPUCommandEncoder, depth: Int) {
        guard let target = ensureShaderLayerTarget(at: depth) else { return }
        beginX3DPass(target.view, load: .clear(SIMD4(0, 0, 0, 0)), encoder: encoder).map(endX3DPass)
        var viewIndex = 0
        for case .render(let render) in x3d.graph.passes {
            guard render.target == .output else {
                viewIndex += render.items.filter { if case .view = $0 { return true } else { return false } }.count
                continue
            }
            var active = beginX3DPass(target.view, load: render.load, encoder: encoder)
            for item in render.items {
                switch item {
                case .draw(let draw):
                    if let active { encodeX3DDraw(draw, rect: x3d.rect, pass: active) }
                case .blit:
                    continue
                case .view:
                    active.map(endX3DPass)
                    active = nil
                    if x3d.views.indices.contains(viewIndex) {
                        let frame = x3d.views[viewIndex]
                        drawScene(frame, geometry: makeTransientGeometryBuffers(for: frame), into: target.view,
                                  encoder: encoder, clear: nil, time: x3dTime, depth: depth + 1)
                    }
                    viewIndex += 1
                    active = beginX3DPass(target.view, load: .load, encoder: encoder)
                }
            }
            active.map(endX3DPass)
        }
        runLayerPost(into: parent, sourceView: target.view, time: x3dTime,
                     layer: CompiledShaderLayer(rect: x3d.rect, shader: X3DCompositeShader().erased(),
                                                frame: CompiledFrame()),
                     encoder: encoder)
    }

    private func beginX3DPass(_ view: WGPUTextureView, load: X3DLoad,
                              encoder: WGPUCommandEncoder) -> WGPURenderPassEncoder? {
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
        return withUnsafePointer(to: &attachment) { pointer in
            var descriptor = WGPURenderPassDescriptor()
            descriptor.colorAttachmentCount = 1
            descriptor.colorAttachments = pointer
            return wgpuCommandEncoderBeginRenderPass(encoder, &descriptor)
        }
    }

    private func endX3DPass(_ pass: WGPURenderPassEncoder) {
        wgpuRenderPassEncoderEnd(pass)
        wgpuRenderPassEncoderRelease(pass)
    }

    private func encodeX3DDraw(_ draw: X3DDraw, rect: PixelRect, pass: WGPURenderPassEncoder) {
        guard let pipeline = x3dPipeline(for: draw), let layout = x3dGroupLayout else { return }
        let x = min(rect.x, configuredWidth), y = min(rect.y, configuredHeight)
        let width = min(rect.width, configuredWidth - x), height = min(rect.height, configuredHeight - y)
        guard width > 0, height > 0 else { return }

        var frame: [UInt32] = [
            Float(width).bitPattern, Float(height).bitPattern,
            Float(x).bitPattern, Float(y).bitPattern,
            x3dTime.bitPattern, x3dDeltaTime.bitPattern,
            x3dFrameIndex, 0,
        ]
        var params = draw.uniforms
        while params.count < 4 { params.append(0) }
        guard let frameBuffer = makeX3DBuffer(bytes: &frame, usage: WGPUBufferUsage_Uniform),
              let paramsBuffer = makeX3DBuffer(bytes: &params, usage: WGPUBufferUsage_Storage) else { return }

        var entries = [WGPUBindGroupEntry(), WGPUBindGroupEntry()]
        entries[0].binding = 0; entries[0].buffer = frameBuffer; entries[0].size = UInt64(frame.count * 4)
        entries[1].binding = 1; entries[1].buffer = paramsBuffer; entries[1].size = UInt64(params.count * 4)
        let bindGroup = entries.withUnsafeBufferPointer { pointer -> WGPUBindGroup? in
            var descriptor = WGPUBindGroupDescriptor()
            descriptor.layout = layout
            descriptor.entryCount = pointer.count
            descriptor.entries = pointer.baseAddress
            return wgpuDeviceCreateBindGroup(device, &descriptor)
        }
        guard let bindGroup else { return }
        transientPostBindGroups.append(bindGroup)

        wgpuRenderPassEncoderSetPipeline(pass, pipeline)
        wgpuRenderPassEncoderSetBindGroup(pass, 0, bindGroup, 0, nil)
        wgpuRenderPassEncoderSetViewport(pass, Float(x), Float(y), Float(width), Float(height), 0, 1)
        wgpuRenderPassEncoderSetScissorRect(pass, x, y, width, height)
        wgpuRenderPassEncoderDraw(pass, UInt32(draw.vertexCount), UInt32(draw.instanceCount), 0, 0)
    }

    private func makeX3DBuffer<T>(bytes: inout [T], usage: WGPUBufferUsage) -> WGPUBuffer? {
        let size = bytes.count * MemoryLayout<T>.stride
        var descriptor = WGPUBufferDescriptor()
        descriptor.usage = usage | WGPUBufferUsage_CopyDst
        descriptor.size = UInt64(size)
        guard let buffer = wgpuDeviceCreateBuffer(device, &descriptor) else { return nil }
        bytes.withUnsafeBytes { wgpuQueueWriteBuffer(queue, buffer, 0, $0.baseAddress, size) }
        transientPostUniformBuffers.append(buffer)
        return buffer
    }

    private func x3dModule(for key: ShaderKey) -> WGPUShaderModule? {
        if let module = x3dModules[key] { return module }
        guard let source = x3dShaderSources[key] else {
            rendererLog("[X3D] no shader registered for \(key.rawValue)")
            return nil
        }
        guard let module = Self.makeShaderModule(device: device, wgsl: x3dPreludeWGSL + source) else { return nil }
        x3dModules[key] = module
        return module
    }

    private func ensureX3DLayouts() -> WGPUPipelineLayout? {
        if let x3dPipelineLayout { return x3dPipelineLayout }
        var entries = [WGPUBindGroupLayoutEntry(), WGPUBindGroupLayoutEntry()]
        let stages = WGPUShaderStage_Vertex | WGPUShaderStage_Fragment | WGPUShaderStage_Compute
        entries[0].binding = 0
        entries[0].visibility = stages
        entries[0].buffer.type = WGPUBufferBindingType_Uniform
        entries[1].binding = 1
        entries[1].visibility = stages
        entries[1].buffer.type = WGPUBufferBindingType_ReadOnlyStorage
        let groupLayout = entries.withUnsafeBufferPointer { pointer -> WGPUBindGroupLayout? in
            var descriptor = WGPUBindGroupLayoutDescriptor()
            descriptor.entryCount = pointer.count
            descriptor.entries = pointer.baseAddress
            return wgpuDeviceCreateBindGroupLayout(device, &descriptor)
        }
        guard let groupLayout else { return nil }
        let layouts: [WGPUBindGroupLayout?] = [groupLayout]
        let pipelineLayout = layouts.withUnsafeBufferPointer { pointer -> WGPUPipelineLayout? in
            var descriptor = WGPUPipelineLayoutDescriptor()
            descriptor.bindGroupLayoutCount = pointer.count
            descriptor.bindGroupLayouts = pointer.baseAddress
            return wgpuDeviceCreatePipelineLayout(device, &descriptor)
        }
        guard let pipelineLayout else {
            wgpuBindGroupLayoutRelease(groupLayout)
            return nil
        }
        x3dGroupLayout = groupLayout
        x3dPipelineLayout = pipelineLayout
        return pipelineLayout
    }

    private func x3dPipeline(for draw: X3DDraw) -> WGPURenderPipeline? {
        let key = "\(draw.shader.rawValue)|\(draw.vertexEntry)|\(draw.fragmentEntry)|\(draw.topology)|\(draw.blend)"
        if let pipeline = x3dPipelines[key] { return pipeline }
        guard let layout = ensureX3DLayouts(), let module = x3dModule(for: draw.shader) else { return nil }
        let pipeline = withWGPUString(draw.vertexEntry) { vertexEntry in
            withWGPUString(draw.fragmentEntry) { fragmentEntry -> WGPURenderPipeline? in
                var blend = WGPUBlendState()
                blend.color.operation = WGPUBlendOperation_Add
                blend.alpha.operation = WGPUBlendOperation_Add
                blend.color.srcFactor = WGPUBlendFactor_One
                blend.alpha.srcFactor = WGPUBlendFactor_One
                switch draw.blend {
                case .additive:
                    blend.color.dstFactor = WGPUBlendFactor_One
                    blend.alpha.dstFactor = WGPUBlendFactor_One
                case .alpha, .opaque:
                    blend.color.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha
                    blend.alpha.dstFactor = WGPUBlendFactor_OneMinusSrcAlpha
                }
                return withUnsafePointer(to: &blend) { blendPointer in
                    var target = WGPUColorTargetState()
                    target.format = surfaceFormat
                    target.blend = draw.blend == .opaque ? nil : blendPointer
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
                            return wgpuDeviceCreateRenderPipeline(device, &descriptor)
                        }
                    }
                }
            }
        }
        if let pipeline { x3dPipelines[key] = pipeline }
        return pipeline
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
