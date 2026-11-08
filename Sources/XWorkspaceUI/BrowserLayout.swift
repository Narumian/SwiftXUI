import Foundation
import XUI

/// How the browser arranges itself in the box it is given. Decided from the box's
/// size alone, so the host never passes an orientation and a split-view resize
/// just re-runs this.
public struct BrowserLayout: Equatable, Sendable {
    /// The box's aspect class.
    public enum Shape: Sendable { case tall, wide, square }
    /// Where the navigation controls sit.
    public enum Chrome: Sendable {
        /// A bar above the items.
        case top
        /// A narrow column left of a horizontally scrolling strip.
        case leading
        /// A folder column beside the items, plus a bar above them.
        case sidebar
    }

    public var shape: Shape
    public var chrome: Chrome
    public var axis: Axis
    public var tracks: Int
    public var itemLength: GridItemLength
    public var spacing: Double
    /// One-line rows instead of tiles (narrow boxes).
    public var usesRows: Bool
    public var headerHeight: Double
    public var chromeWidth: Double
}

public struct BrowserLayoutPolicy: Sendable {
    public var minCell: Double = 104
    public var rowHeight: Double = 52
    public var spacing: Double = 4
    public var headerHeight: Double = 44
    public var leadingWidth: Double = 72
    public var sidebarWidth: Double = 200
    public var maxTracks: Int = 12
    /// Below this content width, one-line rows read better than tiles whose names would truncate.
    public var rowsBelowWidth: Double = 280
    /// A box shorter than this, and wider than it is tall, becomes a filmstrip.
    public var stripHeight: Double = 260
    /// Boxes at least this big get the folder column.
    public var sidebarMinimum = Size(width: 720, height: 360)
    /// Aspect ratios (width / height). The exit thresholds sit inside the entry
    /// thresholds so a box resized across a boundary does not flicker between shapes.
    public var tallEnter = 0.8, tallExit = 0.92
    public var wideEnter = 1.3, wideExit = 1.15

    public init() {}

    public func shape(for size: Size, previous: BrowserLayout.Shape? = nil) -> BrowserLayout.Shape {
        guard size.height > 0, size.width > 0 else { return previous ?? .square }
        let aspect = size.width / size.height
        switch previous {
        case .tall? where aspect <= tallExit: return .tall
        case .wide? where aspect >= wideExit: return .wide
        default:
            if aspect < tallEnter { return .tall }
            if aspect > wideEnter { return .wide }
            return .square
        }
    }

    public func layout(for size: Size, previous: BrowserLayout.Shape? = nil) -> BrowserLayout {
        let shape = shape(for: size, previous: previous)
        if shape == .wide, size.height < stripHeight {
            let usable = max(0, size.height - 2 * spacing)
            let tracks = usable >= 2 * (minCell * 0.8) + spacing ? 2 : 1
            return BrowserLayout(shape: shape, chrome: .leading, axis: .horizontal, tracks: tracks, itemLength: .aspect(1.25),
                                 spacing: spacing, usesRows: false, headerHeight: 0, chromeWidth: leadingWidth)
        }
        let sidebar = size.width >= sidebarMinimum.width && size.height >= sidebarMinimum.height
        let chromeWidth = sidebar ? sidebarWidth : 0
        let contentWidth = max(0, size.width - chromeWidth - 2 * spacing)
        let fitting = Int((contentWidth + spacing) / (minCell + spacing))
        if fitting < 2 || contentWidth < rowsBelowWidth {
            return BrowserLayout(shape: shape, chrome: sidebar ? .sidebar : .top, axis: .vertical, tracks: 1, itemLength: .fixed(rowHeight),
                                 spacing: 2, usesRows: true, headerHeight: headerHeight, chromeWidth: chromeWidth)
        }
        return BrowserLayout(shape: shape, chrome: sidebar ? .sidebar : .top, axis: .vertical, tracks: min(maxTracks, fitting), itemLength: .aspect(1),
                             spacing: spacing, usesRows: false, headerHeight: headerHeight, chromeWidth: chromeWidth)
    }
}
