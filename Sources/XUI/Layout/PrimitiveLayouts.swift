import Foundation

/// Root of every render: each top-level node is proposed the full canvas and
/// pinned top-leading at its own measured size. A view that means to own the
/// whole canvas fills explicitly (`.frame(maxWidth: .infinity, maxHeight: .infinity)`
/// or a filling stack).
struct RootLayout: NodeLayout {
    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        proposal.resolved()
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        for child in children {
            let size = LayoutEngine.measure(child, ProposedSize(rect.size), context)
            child.frame = Rect(origin: rect.origin, size: size)
        }
    }
}

/// A leaf that takes exactly what it is offered (SwiftUI's `Color` / `Rectangle`
/// flexibility). With an unspecified proposal it collapses to an ideal 10×10.
struct FillLayout: NodeLayout {
    var ideal: Size = Size(width: 10, height: 10)

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        proposal.resolved(fallback: ideal)
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {}
}

/// A leaf of a fixed, caller-declared size that ignores the proposal.
struct FixedSizeLayout: NodeLayout {
    var size: Size

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size { size }
    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {}
}

/// Wraps content transparently so a modifier that needs a single node to hang
/// off (`.anchor`, `.region`) has one even when its content lowered to many.
struct PassthroughLayout: NodeLayout {
    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        guard !children.isEmpty else { return proposal.resolved() }
        var result = Size.zero
        for child in children {
            let size = child.measure(proposal, context)
            result = Size(width: max(result.width, size.width), height: max(result.height, size.height))
        }
        return result
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        for child in children {
            let size = child.measure(ProposedSize(rect.size), context)
            child.frame = Rect(origin: rect.origin, size: size)
        }
    }
}
