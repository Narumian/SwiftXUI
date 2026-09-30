import Foundation

/// Expands only `// shader-include: foundation/<file>.wgsl` directives.
public enum WGSLSourceAssembler {
    public enum Error: Swift.Error, Equatable, Sendable {
        case missingSource(String), invalidInclude(String), includeOutsideFoundation(String)
        case includeCycle([String])
    }

    public static func assemble(root: String, sources: [String: String]) throws -> String {
        guard sources[root] != nil else { throw Error.missingSource(root) }
        var active: [String] = [], emitted = Set<String>()
        return try expand(root, sources: sources, active: &active, emitted: &emitted)
    }

    public static func assemble(rootSourceName: String, sourceMap: [String: String]) throws -> String {
        try assemble(root: rootSourceName, sources: sourceMap)
    }

    private static func expand(_ name: String, sources: [String: String], active: inout [String], emitted: inout Set<String>) throws -> String {
        guard let source = sources[name] else { throw Error.missingSource(name) }
        guard !active.contains(name) else { throw Error.includeCycle(active + [name]) }
        guard emitted.insert(name).inserted else { return "" }
        active.append(name)
        defer { _ = active.popLast() }
        var result: [String] = []
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("// shader-include:") {
                let path = trimmed.dropFirst("// shader-include:".count).trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty, !path.contains("\\"), !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw Error.invalidInclude(String(path)) }
                guard path.lowercased().hasPrefix("foundation/") else { throw Error.includeOutsideFoundation(String(path)) }
                let requested = String(path)
                let resolved = sources[requested] != nil ? requested :
                    (sources.keys.first { $0.lowercased() == requested.lowercased() } ?? canonicalFoundationPath(requested))
                guard resolved.lowercased().hasPrefix("foundation/") else { throw Error.includeOutsideFoundation(requested) }
                result.append(try expand(resolved, sources: sources, active: &active, emitted: &emitted))
            } else { result.append(line) }
        }
        return result.joined(separator: "\n")
    }

    private static func canonicalFoundationPath(_ path: String) -> String {
        "foundation/" + path.split(separator: "/").dropFirst().joined(separator: "/")
    }
}
