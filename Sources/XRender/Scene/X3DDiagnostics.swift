import Foundation
import XShader

/// A localized problem in an `X3DGraph`: which pass / item / entry failed and why.
public struct X3DDiagnostic: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case unregisteredShader(ShaderKey)
        case undeclaredBinding(X3DResourceID)
        case undeclaredPassTarget(X3DResourceID)
        case undeclaredBlit(X3DResourceID)
    }

    public enum Site: Sendable, Equatable {
        case compute(pass: Int, entry: String)
        case draw(pass: Int, item: Int, vertex: String, fragment: String)
        case blit(pass: Int, item: Int)
        case pass(pass: Int)
    }

    public var kind: Kind
    public var site: Site

    public init(kind: Kind, site: Site) {
        self.kind = kind
        self.site = site
    }

    public var description: String {
        "\(siteDescription): \(kindDescription)"
    }

    private var siteDescription: String {
        switch site {
        case .compute(let pass, let entry):
            return "compute pass[\(pass)] entry \(entry)"
        case .draw(let pass, let item, let vertex, let fragment):
            return "draw pass[\(pass)] item[\(item)] \(vertex)/\(fragment)"
        case .blit(let pass, let item):
            return "blit pass[\(pass)] item[\(item)]"
        case .pass(let pass):
            return "pass[\(pass)]"
        }
    }

    private var kindDescription: String {
        switch kind {
        case .unregisteredShader(let key):
            return "ShaderKey \"\(key.rawValue)\" is not registered"
        case .undeclaredBinding(let id):
            return "binding \"\(id.name)\" (scope \(id.scope)) is not declared"
        case .undeclaredPassTarget(let id):
            return "pass target \"\(id.name)\" (scope \(id.scope)) is not declared"
        case .undeclaredBlit(let id):
            return "blit source \"\(id.name)\" (scope \(id.scope)) is not declared"
        }
    }
}

/// Graph-level checks for the authoring mistakes the encoder currently only logs.
public enum X3DDiagnostics {
    /// Keys the stock WGPU encoder always provides (fullscreen / blit / fade / plane).
    public static let builtinShaders: Set<ShaderKey> = ["swiftx.x3d"]

    /// Returns every ShaderKey miss and undeclared binding / target / blit in `graph`.
    ///
    /// Pass `registeredShaders: nil` to skip ShaderKey checks (binding-only).
    /// Builtin keys in `builtinShaders` are always treated as registered.
    public static func issues(
        in graph: X3DGraph,
        registeredShaders: Set<ShaderKey>? = nil
    ) -> [X3DDiagnostic] {
        let declared = Set(graph.resources.map(\.id))
        let known = registeredShaders.map { $0.union(builtinShaders) }
        var found: [X3DDiagnostic] = []

        for (passIndex, pass) in graph.passes.enumerated() {
            switch pass {
            case .compute(let compute):
                let site = X3DDiagnostic.Site.compute(pass: passIndex, entry: compute.entry)
                if let known, !known.contains(compute.shader) {
                    found.append(X3DDiagnostic(kind: .unregisteredShader(compute.shader), site: site))
                }
                for binding in compute.bindings where !declared.contains(binding.resource) {
                    found.append(X3DDiagnostic(kind: .undeclaredBinding(binding.resource), site: site))
                }
            case .render(let render):
                if case .texture(let id) = render.target, !declared.contains(id) {
                    found.append(X3DDiagnostic(
                        kind: .undeclaredPassTarget(id),
                        site: .pass(pass: passIndex)
                    ))
                }
                for (itemIndex, item) in render.items.enumerated() {
                    switch item {
                    case .draw(let draw):
                        let site = X3DDiagnostic.Site.draw(
                            pass: passIndex, item: itemIndex,
                            vertex: draw.vertexEntry, fragment: draw.fragmentEntry
                        )
                        if let known, !known.contains(draw.shader) {
                            found.append(X3DDiagnostic(kind: .unregisteredShader(draw.shader), site: site))
                        }
                        for binding in draw.bindings where !declared.contains(binding.resource) {
                            found.append(X3DDiagnostic(kind: .undeclaredBinding(binding.resource), site: site))
                        }
                    case .blit(let id, _):
                        if !declared.contains(id) {
                            found.append(X3DDiagnostic(
                                kind: .undeclaredBlit(id),
                                site: .blit(pass: passIndex, item: itemIndex)
                            ))
                        }
                    case .view, .plane:
                        break
                    }
                }
            }
        }
        return found
    }

    /// Collects issues and, in debug builds, asserts when any are present.
    @discardableResult
    public static func assertValid(
        _ graph: X3DGraph,
        registeredShaders: Set<ShaderKey>? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) -> [X3DDiagnostic] {
        let found = issues(in: graph, registeredShaders: registeredShaders)
        assert(
            found.isEmpty,
            found.map(\.description).joined(separator: "\n"),
            file: file,
            line: line
        )
        return found
    }
}

public extension X3DGraph {
    /// Convenience for authors and Host tests: same as `X3DDiagnostics.issues`.
    func diagnose(registeredShaders: Set<ShaderKey>? = nil) -> [X3DDiagnostic] {
        X3DDiagnostics.issues(in: self, registeredShaders: registeredShaders)
    }
}
