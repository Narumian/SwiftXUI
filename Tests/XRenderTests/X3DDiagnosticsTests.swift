import Testing
import XShader
@testable import XRender

private let particles = X3DResourceID(scope: 1, name: "particles")
private let trail = X3DResourceID(scope: 1, name: "trail")
private let missing = X3DResourceID(scope: 1, name: "ghost")

private func flowGraph(bindGhost: Bool = false) -> X3DGraph {
    let particleBinding = X3DBinding(resource: particles, access: .readWrite)
    let drawBinding = X3DBinding(
        resource: bindGhost ? missing : particles,
        access: .read
    )
    return X3DGraph(
        resources: [
            .buffer(id: particles, byteCount: 64),
            .texture(id: trail, format: .rgba16Float, size: .target),
        ],
        passes: [
            .compute(X3DCompute(
                shader: "flow", entry: "step", threads: 4,
                bindings: [particleBinding], uniforms: [0.5]
            )),
            .render(X3DRenderPass(
                target: .texture(trail), load: .fade(0.1),
                items: [
                    .draw(X3DDraw(
                        shader: "flow", vertexEntry: "vs_main", fragmentEntry: "fs_main",
                        vertexCount: 6, instanceCount: 4, blend: .additive,
                        bindings: [drawBinding]
                    )),
                ]
            )),
            .render(X3DRenderPass(
                target: .output, load: .load,
                items: [.blit(trail, blend: .alpha)]
            )),
        ]
    )
}

@Test func diagnoseReportsUnregisteredShaderWithPassSite() {
    let issues = flowGraph().diagnose(registeredShaders: [])
    #expect(issues.count == 2)
    #expect(issues[0] == X3DDiagnostic(
        kind: .unregisteredShader("flow"),
        site: .compute(pass: 0, entry: "step")
    ))
    #expect(issues[1] == X3DDiagnostic(
        kind: .unregisteredShader("flow"),
        site: .draw(pass: 1, item: 0, vertex: "vs_main", fragment: "fs_main")
    ))
    #expect(issues[0].description.contains("ShaderKey \"flow\""))
    #expect(issues[0].description.contains("compute pass[0]"))
}

@Test func diagnoseAcceptsRegisteredAndBuiltinShaders() {
    let graph = X3DGraph(passes: [
        .render(X3DRenderPass(target: .output, load: .load, items: [
            .draw(X3DDraw(
                shader: "swiftx.x3d", vertexEntry: "x3d_fullscreen", fragmentEntry: "x3d_blit",
                vertexCount: 3
            )),
            .draw(X3DDraw(
                shader: "flow", vertexEntry: "vs_main", fragmentEntry: "fs_main",
                vertexCount: 3
            )),
        ])),
    ])
    let issues = graph.diagnose(registeredShaders: ["flow"])
    #expect(issues.isEmpty)
    #expect(X3DDiagnostics.builtinShaders.contains("swiftx.x3d"))
}

@Test func diagnoseReportsUndeclaredBindingAndPassTarget() {
    let graph = X3DGraph(
        resources: [.buffer(id: particles, byteCount: 16)],
        passes: [
            .render(X3DRenderPass(
                target: .texture(trail), load: .load,
                items: [
                    .draw(X3DDraw(
                        shader: "flow", vertexEntry: "vs_main", fragmentEntry: "fs_main",
                        vertexCount: 3,
                        bindings: [X3DBinding(resource: missing, access: .read)]
                    )),
                    .blit(missing, blend: .alpha),
                ]
            )),
        ]
    )
    let issues = graph.diagnose(registeredShaders: ["flow"])
    #expect(issues == [
        X3DDiagnostic(kind: .undeclaredPassTarget(trail), site: .pass(pass: 0)),
        X3DDiagnostic(kind: .undeclaredBinding(missing), site: .draw(
            pass: 0, item: 0, vertex: "vs_main", fragment: "fs_main"
        )),
        X3DDiagnostic(kind: .undeclaredBlit(missing), site: .blit(pass: 0, item: 1)),
    ])
}

@Test func diagnoseSkipsShaderChecksWhenRegistryIsNil() {
    let issues = flowGraph(bindGhost: true).diagnose(registeredShaders: nil)
    #expect(issues == [
        X3DDiagnostic(
            kind: .undeclaredBinding(missing),
            site: .draw(pass: 1, item: 0, vertex: "vs_main", fragment: "fs_main")
        ),
    ])
}

@Test func assertValidReturnsEmptyOnHealthyGraph() {
    let found = X3DDiagnostics.assertValid(flowGraph(), registeredShaders: ["flow"])
    #expect(found.isEmpty)
}
