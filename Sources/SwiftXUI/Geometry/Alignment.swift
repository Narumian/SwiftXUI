import Foundation

/// Where a child sits along the horizontal axis when it is smaller than its slot.
/// `fraction` is 0 at leading, 0.5 at center, 1 at trailing.
public enum HorizontalAlignment: Hashable, Sendable {
    case leading
    case center
    case trailing

    public var fraction: Double {
        switch self {
        case .leading: return 0
        case .center: return 0.5
        case .trailing: return 1
        }
    }
}

/// Where a child sits along the vertical axis when it is smaller than its slot.
public enum VerticalAlignment: Hashable, Sendable {
    case top
    case center
    case bottom

    public var fraction: Double {
        switch self {
        case .top: return 0
        case .center: return 0.5
        case .bottom: return 1
        }
    }
}

/// A 2-D alignment, used by `ZStack` and `.frame(...)`.
public struct Alignment: Hashable, Sendable {
    public var horizontal: HorizontalAlignment
    public var vertical: VerticalAlignment

    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let center = Alignment(horizontal: .center, vertical: .center)
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    public static let top = Alignment(horizontal: .center, vertical: .top)
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)

    /// Place `child` inside `slot` honouring this alignment.
    public func position(_ child: Size, in slot: Rect) -> Rect {
        Rect(
            x: slot.x + horizontal.fraction * (slot.width - child.width),
            y: slot.y + vertical.fraction * (slot.height - child.height),
            width: child.width,
            height: child.height
        )
    }
}
