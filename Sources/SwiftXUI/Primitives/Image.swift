import Foundation

/// A renderer-agnostic image identifier plus its natural layout size.
///
/// `SwiftXUI` deliberately does not know whether this becomes a texture, an
/// asset catalog entry, an SVG, or something else. Backends resolve `name`.
public struct ImageSource: Hashable, Sendable {
    public var name: String
    public var naturalSize: Size

    public init(_ name: String, naturalSize: Size) {
        self.name = name
        self.naturalSize = naturalSize
    }
}

struct ImageLayout: NodeLayout {
    var source: ImageSource
    var resizing: Image.Resizing

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        switch resizing {
        case .fixed:
            return source.naturalSize
        case .resizable:
            return proposal.resolved(fallback: source.naturalSize)
        }
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {}
}

/// SwiftUI-like image leaf. Fixed at its natural size until `.resizable()` is
/// applied; combine `.resizable()` with `.scaledToFit()` / `.scaledToFill()` for
/// aspect-preserving layout.
public struct Image: XView, _PrimitiveXView {
    public typealias Body = Never

    enum Resizing: Sendable {
        case fixed
        case resizable
    }

    public var source: ImageSource
    public var opacity: Double
    var resizing: Resizing

    public init(_ source: ImageSource) {
        self.source = source
        self.opacity = 1
        self.resizing = .fixed
    }

    func _lower(id: StateIdentity, store: StateStore) -> [LayoutNode] {
        let node = LayoutNode(layout: ImageLayout(source: source, resizing: resizing))
        let source = self.source
        let opacity = self.opacity
        node.draw = { rect, context in
            context.canvas.drawImage(source, in: rect, opacity: opacity)
        }
        return [node]
    }

    public func resizable() -> Self {
        var copy = self
        copy.resizing = .resizable
        return copy
    }

    public func opacity(_ amount: Double) -> Self {
        var copy = self
        copy.opacity *= amount
        return copy
    }
}
