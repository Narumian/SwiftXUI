import Foundation

/// How an aspect-ratio box is resolved against the space its parent offers.
public enum AspectContentMode: Sendable {
    /// Keep the whole box visible within the offered size.
    case fit
    /// Cover the offered size, allowing the box to exceed it on one axis.
    case fill
}

struct AspectRatioLayout: NodeLayout {
    var ratio: Double?
    var contentMode: AspectContentMode
    var alignment: Alignment

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        let childIdeal = idealChildSize(children, context)
        let aspect = resolvedAspect(childIdeal: childIdeal)
        return aspectSize(for: proposal, aspect: aspect, childIdeal: childIdeal)
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        guard let child = children.first else { return }
        let proposal = ProposedSize(rect.size)
        let childIdeal = idealChildSize(children, context)
        let aspect = resolvedAspect(childIdeal: childIdeal)
        let box = aspectSize(for: proposal, aspect: aspect, childIdeal: childIdeal)
        let childSize = child.measure(ProposedSize(box), context)
        child.frame = alignment.position(childSize, in: Rect(origin: rect.origin, size: box))
    }

    private func idealChildSize(_ children: [LayoutNode], _ context: LayoutContext) -> Size {
        children.first.map { $0.measure(.unspecified, context) } ?? Size(width: 10, height: 10)
    }

    private func resolvedAspect(childIdeal: Size) -> Double {
        if let ratio, ratio.isFinite, ratio > 0 { return ratio }
        guard childIdeal.width > 0, childIdeal.height > 0 else { return 1 }
        return childIdeal.width / childIdeal.height
    }

    private func aspectSize(for proposal: ProposedSize, aspect: Double, childIdeal: Size) -> Size {
        let w = finite(proposal.width)
        let h = finite(proposal.height)

        switch (w, h) {
        case (.some(let width), .some(let height)):
            guard width > 0, height > 0 else { return .zero }
            let proposedAspect = width / height
            switch contentMode {
            case .fit:
                return proposedAspect > aspect
                    ? Size(width: height * aspect, height: height)
                    : Size(width: width, height: width / aspect)
            case .fill:
                return proposedAspect > aspect
                    ? Size(width: width, height: width / aspect)
                    : Size(width: height * aspect, height: height)
            }
        case (.some(let width), .none):
            return width > 0 ? Size(width: width, height: width / aspect) : .zero
        case (.none, .some(let height)):
            return height > 0 ? Size(width: height * aspect, height: height) : .zero
        case (.none, .none):
            if childIdeal.width > 0 { return Size(width: childIdeal.width, height: childIdeal.width / aspect) }
            if childIdeal.height > 0 { return Size(width: childIdeal.height * aspect, height: childIdeal.height) }
            return Size(width: 10 * aspect, height: 10)
        }
    }

    private func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }
}

public struct _AspectRatioModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let ratio: Double?
    let contentMode: AspectContentMode
    let alignment: Alignment

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        [LayoutNode(
            layout: AspectRatioLayout(ratio: ratio, contentMode: contentMode, alignment: alignment),
            children: await lower(content, id: id, store: store)
        )]
    }
}

public extension XView {
    /// Resolve this view to a fixed width:height ratio within the offered size.
    /// Pass `nil` to use the child's ideal measured aspect.
    func aspectRatio(
        _ ratio: Double? = nil,
        contentMode: AspectContentMode = .fit,
        alignment: Alignment = .center
    ) -> _AspectRatioModifier<Self> {
        _AspectRatioModifier(content: self, ratio: ratio, contentMode: contentMode, alignment: alignment)
    }

    /// Short alias for `aspectRatio`.
    func aspect(
        _ ratio: Double? = nil,
        contentMode: AspectContentMode = .fit,
        alignment: Alignment = .center
    ) -> _AspectRatioModifier<Self> {
        aspectRatio(ratio, contentMode: contentMode, alignment: alignment)
    }

    /// Preserve the child's ideal aspect while fitting inside the offered size.
    func scaledToFit(alignment: Alignment = .center) -> _AspectRatioModifier<Self> {
        aspectRatio(nil, contentMode: .fit, alignment: alignment)
    }

    /// Preserve the child's ideal aspect while covering the offered size.
    func scaledToFill(alignment: Alignment = .center) -> _AspectRatioModifier<Self> {
        aspectRatio(nil, contentMode: .fill, alignment: alignment)
    }
}
