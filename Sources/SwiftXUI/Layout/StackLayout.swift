import Foundation

/// `VStack` / `HStack`. Distributes main-axis space with SwiftUI's flexibility
/// rule: probe every child's `[min, max]` main length, serve the least-flexible
/// first, re-dividing the remainder each step.
struct StackLayout: NodeLayout {
    var axis: Axis
    var spacing: Double
    /// 0 = leading/top edge, 0.5 = centre, 1 = trailing/bottom edge.
    var crossFraction: Double

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        guard !children.isEmpty else { return .zero }
        let crossProposal = axis.crossComponent(proposal)
        let lengths = mainLengths(proposal, children, context)
        let mainTotal = lengths.reduce(0, +) + spacing * Double(children.count - 1)

        var crossMax = 0.0
        for (index, child) in children.enumerated() where !child.isSpacer {
            let size = child.measure(axis.proposal(main: lengths[index], cross: crossProposal), context)
            crossMax = max(crossMax, axis.crossLength(size))
        }
        return axis.size(main: mainTotal, cross: crossMax)
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        guard !children.isEmpty else { return }
        let proposal = ProposedSize(rect.size)
        let lengths = mainLengths(proposal, children, context)
        let availableCross = axis.crossLength(rect)
        let crossOrigin = axis == .horizontal ? rect.y : rect.x

        var cursor = axis == .horizontal ? rect.x : rect.y
        for (index, child) in children.enumerated() {
            let mainLen = lengths[index]
            let childSize = child.isSpacer
                ? axis.size(main: mainLen, cross: 0)
                : child.measure(axis.proposal(main: mainLen, cross: availableCross), context)
            let childCross = axis.crossLength(childSize)
            let childCrossOrigin = crossOrigin + crossFraction * (availableCross - childCross)
            child.frame = axis.rect(
                mainOrigin: cursor,
                mainLength: axis.mainLength(childSize),
                crossOrigin: childCrossOrigin,
                crossLength: childCross
            )
            cursor += mainLen + spacing
        }
    }

    // MARK: distribution

    private func mainLengths(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> [Double] {
        let count = children.count
        guard count > 0 else { return [] }
        let crossProposal = axis.crossComponent(proposal)

        // No main-axis proposal → asked for our ideal: each child at its ideal.
        guard let availableMain = axis.mainComponent(proposal) else {
            return children.map { child in
                child.isSpacer
                    ? child.spacerMinLength
                    : axis.mainLength(child.measure(axis.proposal(main: nil, cross: crossProposal), context))
            }
        }

        var remaining = availableMain - spacing * Double(count - 1)
        var result = [Double](repeating: 0, count: count)
        var served = 0

        for index in orderByFlexibility(children, context) {
            let share = served < count ? max(0, remaining / Double(count - served)) : 0
            let taken: Double
            if children[index].isSpacer {
                taken = max(children[index].spacerMinLength, share)
            } else {
                taken = axis.mainLength(children[index].measure(axis.proposal(main: share, cross: crossProposal), context))
            }
            result[index] = taken
            remaining -= taken
            served += 1
        }
        return result
    }

    private func orderByFlexibility(_ children: [LayoutNode], _ context: LayoutContext) -> [Int] {
        let flex = children.map { flexibility($0, context) }
        return (0..<children.count).sorted { a, b in
            flex[a] == flex[b] ? a < b : flex[a] < flex[b]
        }
    }

    private func flexibility(_ child: LayoutNode, _ context: LayoutContext) -> Double {
        if child.isSpacer { return .infinity }
        let low = axis.mainLength(child.measure(axis.proposal(main: 0, cross: nil), context))
        let high = axis.mainLength(child.measure(axis.proposal(main: .infinity, cross: nil), context))
        return max(0, high - low)
    }
}

/// `ZStack`. Every child is proposed the full space and aligned within it.
struct ZStackLayout: NodeLayout {
    var alignment: Alignment

    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        var result = Size.zero
        for child in children {
            let size = child.measure(proposal, context)
            result = Size(width: max(result.width, size.width), height: max(result.height, size.height))
        }
        return result
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {
        let proposal = ProposedSize(rect.size)
        for child in children {
            let size = child.measure(proposal, context)
            child.frame = alignment.position(size, in: rect)
        }
    }
}
