import Foundation
import XShader

/// An `X3DView`'s lowered program, composited at its place in paint order.
public struct X3DCommand: Sendable, Equatable {
    public var rect: RenderRect
    public var graph: X3DGraph

    public init(rect: RenderRect, graph: X3DGraph) {
        self.rect = rect
        self.graph = graph
    }
}

public struct X3DGraph: Sendable, Equatable {
    public var resources: [X3DResource]
    public var passes: [X3DPass]

    public init(resources: [X3DResource] = [], passes: [X3DPass] = []) {
        self.resources = resources
        self.passes = passes
    }

    /// Every embedded view's commands, for consumers that scan a scene
    /// (font preparation) without caring about passes.
    public var viewCommands: [DrawCommand] {
        passes.flatMap { pass -> [DrawCommand] in
            guard case .render(let render) = pass else { return [] }
            return render.items.flatMap { item -> [DrawCommand] in
                guard case .view(_, let commands) = item else { return [] }
                return commands
            }
        }
    }
}

public enum X3DPass: Sendable, Equatable {
    case compute(X3DCompute)
    case render(X3DRenderPass)
}

public struct X3DRenderPass: Sendable, Equatable {
    public var target: X3DTarget
    public var load: X3DLoad
    public var depth: Bool
    public var items: [X3DRenderItem]

    public init(target: X3DTarget, load: X3DLoad, depth: Bool = false, items: [X3DRenderItem] = []) {
        self.target = target
        self.load = load
        self.depth = depth
        self.items = items
    }
}

public enum X3DRenderItem: Sendable, Equatable {
    case draw(X3DDraw)
    case blit(X3DResourceID, blend: X3DBlend)
    case view(rect: RenderRect, commands: [DrawCommand])
}

/// Assembles an `X3DGraph` from the `X3DOp` stream a sink receives.
struct X3DGraphAssembly {
    let rect: RenderRect
    var graph = X3DGraph()
    var pass: X3DRenderPass?
    var viewRect: RenderRect?
    var outerScene: Scene?

    init(rect: RenderRect) { self.rect = rect }

    mutating func apply(_ op: X3DOp) {
        switch op {
        case .resource(let resource):
            if !graph.resources.contains(where: { $0.id == resource.id }) {
                graph.resources.append(resource)
            }
        case .compute(let compute):
            graph.passes.append(.compute(compute))
        case .beginPass(let target, let load, let depth):
            pass = X3DRenderPass(target: target, load: load, depth: depth)
        case .draw(let draw):
            pass?.items.append(.draw(draw))
        case .blit(let id, let blend):
            pass?.items.append(.blit(id, blend: blend))
        case .endPass:
            if let pass { graph.passes.append(.render(pass)) }
            pass = nil
        }
    }
}
