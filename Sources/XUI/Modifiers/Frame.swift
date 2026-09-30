import Foundation

/// A length on one axis: absolute points, or a fraction of the reference size
/// (the canvas). Fractions are anchored to the reference rather than to the
/// parent's offer so they stay put when a wrapper re-measures a placed child.
/// Number literals mean points, so `.frame(width: 300)` keeps working.
public enum Length: Hashable, Sendable, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    case pt(Double)
    case fraction(Double)

    public init(floatLiteral value: Double) { self = .pt(value) }
    public init(integerLiteral value: Int) { self = .pt(Double(value)) }
}

public extension Double {
    /// 1/φ — the smaller golden section, e.g. `.fraction(.golden)`.
    static let golden = 0.618_033_988_749_895
}

/// One axis of a `.frame(...)`: an optional lower bound, ideal, and upper bound.
/// A fixed `.frame(width:)` sets all three equal; a fill sets `max = .infinity`.
struct FrameAxis {
    var min: Double?
    var ideal: Double?
    var max: Double?
    /// When set, the axis is a fixed fraction of the reference size. It is
    /// resolved to a concrete `min = ideal = max` before use (see `concrete`).
    var fraction: Double?

    static let passthrough = FrameAxis(min: nil, ideal: nil, max: nil)

    var isPassthrough: Bool { min == nil && ideal == nil && max == nil && fraction == nil }

    init(min: Double?, ideal: Double?, max: Double?, fraction: Double? = nil) {
        self.min = min
        self.ideal = ideal
        self.max = max
        self.fraction = fraction
    }

    init(_ length: Length?) {
        switch length {
        case nil: self = .passthrough
        case .pt(let v)?: self.init(min: v, ideal: v, max: v)
        case .fraction(let f)?: self.init(min: nil, ideal: nil, max: nil, fraction: f)
        }
    }

    /// Turns a fraction into a fixed length of the reference size. With no
    /// reference there is nothing to take a fraction of, so the axis is left to
    /// the child.
    func concrete(_ reference: Double) -> FrameAxis {
        guard let fraction else { return self }
        guard reference.isFinite, reference > 0 else { return .passthrough }
        let v = reference * fraction
        return FrameAxis(min: v, ideal: v, max: v)
    }

    /// What this axis proposes to the child, given the parent's proposal.
    /// A `nil` proposal falls to `ideal` (child decides if that's nil too).
    func offer(_ proposal: Double?) -> Double? {
        if isPassthrough { return proposal }
        guard var value = proposal else { return ideal }
        if let max { value = Swift.min(value, max) }
        if let min { value = Swift.max(value, min) }
        return value
    }

    /// The length this axis reports, given the child's measured length.
    /// An unconstrained (`nil`) proposal reports `ideal` when set; otherwise the
    /// child's size, always re-clamped to `[min, max]`.
    func resolve(childLength: Double, proposal: Double?) -> Double {
        if isPassthrough { return childLength }
        var value = (proposal == nil ? ideal : nil) ?? childLength
        if let max { value = Swift.min(value, max) }
        if let min { value = Swift.max(value, min) }
        return Swift.max(0, value)
    }
}

struct FrameLayout: NodeLayout {
    var horizontal: FrameAxis
    var vertical: FrameAxis
    var alignment: Alignment

    private func childSize(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        let h = horizontal.concrete(context.referenceSize.width)
        let v = vertical.concrete(context.referenceSize.height)
        let offer = ProposedSize(width: h.offer(proposal.width), height: v.offer(proposal.height))
        return children.first.map { LayoutEngine.measure($0, offer, context) } ?? .zero
    }

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        let h = horizontal.concrete(context.referenceSize.width)
        let v = vertical.concrete(context.referenceSize.height)
        let cs = childSize(proposal, children, context)
        return Size(width: h.resolve(childLength: cs.width, proposal: proposal.width),
                    height: v.resolve(childLength: cs.height, proposal: proposal.height))
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        guard let child = children.first else { return }
        let cs = childSize(ProposedSize(rect.size), children, context)
        child.frame = alignment.position(cs, in: rect)
    }
}

public struct _FrameModifier<Content: XView>: XView, _PrimitiveXView {
    public typealias Body = Never
    let content: Content
    let horizontal: FrameAxis
    let vertical: FrameAxis
    let alignment: Alignment

    @XUIActor
    func _lower(id: StateIdentity, store: StateStore) async -> [LayoutNode] {
        // Inside `.animation(_:value:)` a fixed width or height eases to its new
        // length instead of jumping. Anywhere else this is the axis unchanged.
        let h = animated(horizontal, id: id.child(type: Self.self, index: 1), store)
        let v = animated(vertical, id: id.child(type: Self.self, index: 2), store)
        return [LayoutNode(
            layout: FrameLayout(horizontal: h, vertical: v, alignment: alignment),
            children: await lower(content, id: id, store: store)
        )]
    }

    private func animated(_ axis: FrameAxis, id: StateIdentity, _ store: StateStore) -> FrameAxis {
        guard store.transaction.isActive, axis.fraction == nil,
              let length = axis.min, axis.ideal == length, axis.max == length else { return axis }
        let shown = store.animated(length, id: id)
        return FrameAxis(min: shown, ideal: shown, max: shown)
    }
}

public extension XView {
    /// Fixed size on either or both axes; content is aligned inside the box.
    func frame(
        width: Double? = nil,
        height: Double? = nil,
        alignment: Alignment = .center
    ) -> _FrameModifier<Self> {
        _FrameModifier(
            content: self,
            horizontal: width.map { FrameAxis(min: $0, ideal: $0, max: $0) } ?? .passthrough,
            vertical: height.map { FrameAxis(min: $0, ideal: $0, max: $0) } ?? .passthrough,
            alignment: alignment
        )
    }

    /// Fixed size where either axis may be a `.fraction` of the reference size
    /// (the canvas), e.g. `.frame(width: .fraction(.golden), height: 300)`.
    @_disfavoredOverload
    func frame(
        width: Length? = nil,
        height: Length? = nil,
        alignment: Alignment = .center
    ) -> _FrameModifier<Self> {
        _FrameModifier(content: self, horizontal: FrameAxis(width), vertical: FrameAxis(height),
                       alignment: alignment)
    }

    /// Flexible size. Pass `maxWidth: .infinity` to fill the offered width, a
    /// finite `maxWidth` to grow only up to it, `minWidth` to never shrink past
    /// it, `idealWidth` for the size to report when unconstrained.
    func frame(
        minWidth: Double? = nil,
        idealWidth: Double? = nil,
        maxWidth: Double? = nil,
        minHeight: Double? = nil,
        idealHeight: Double? = nil,
        maxHeight: Double? = nil,
        alignment: Alignment = .center
    ) -> _FrameModifier<Self> {
        _FrameModifier(
            content: self,
            horizontal: FrameAxis(min: minWidth, ideal: idealWidth, max: maxWidth),
            vertical: FrameAxis(min: minHeight, ideal: idealHeight, max: maxHeight),
            alignment: alignment
        )
    }
}
