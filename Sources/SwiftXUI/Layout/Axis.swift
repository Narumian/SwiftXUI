import Foundation

/// The primary direction of a stack. Every stack algorithm is written once in
/// terms of "main" / "cross" and specialised through this.
public enum Axis: Hashable, Sendable {
    case horizontal
    case vertical

    func mainLength(_ size: Size) -> Double {
        self == .horizontal ? size.width : size.height
    }

    func crossLength(_ size: Size) -> Double {
        self == .horizontal ? size.height : size.width
    }

    func mainLength(_ rect: Rect) -> Double {
        self == .horizontal ? rect.width : rect.height
    }

    func crossLength(_ rect: Rect) -> Double {
        self == .horizontal ? rect.height : rect.width
    }

    func mainComponent(_ proposal: ProposedSize) -> Double? {
        self == .horizontal ? proposal.width : proposal.height
    }

    func crossComponent(_ proposal: ProposedSize) -> Double? {
        self == .horizontal ? proposal.height : proposal.width
    }

    func size(main: Double, cross: Double) -> Size {
        self == .horizontal
            ? Size(width: main, height: cross)
            : Size(width: cross, height: main)
    }

    func proposal(main: Double?, cross: Double?) -> ProposedSize {
        self == .horizontal
            ? ProposedSize(width: main, height: cross)
            : ProposedSize(width: cross, height: main)
    }

    /// Build a rect from a main-axis origin/length and a cross-axis origin/length.
    func rect(mainOrigin: Double, mainLength: Double, crossOrigin: Double, crossLength: Double) -> Rect {
        self == .horizontal
            ? Rect(x: mainOrigin, y: crossOrigin, width: mainLength, height: crossLength)
            : Rect(x: crossOrigin, y: mainOrigin, width: crossLength, height: mainLength)
    }
}
