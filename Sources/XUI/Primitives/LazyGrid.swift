import Foundation

/// How long a grid item is along the scrolling axis.
public enum GridItemLength: Hashable, Sendable {
    /// A fixed length in points.
    case fixed(Double)
    /// width / height of every item; the main length follows the cross length,
    /// so the grid keeps square (1) or 16:9 (16/9) cells whatever the track count.
    case aspect(Double)
}

/// Pure grid arithmetic: which rows are visible and where an item sits. Kept
/// free of views so the scroll window can be tested and benchmarked on its own.
struct LazyGridGeometry: Equatable {
    var axis: Axis
    var tracks: Int
    var count: Int
    var spacing: Double
    var length: GridItemLength
    var viewport: Size

    init(axis: Axis, tracks: Int, count: Int, spacing: Double, length: GridItemLength, viewport: Size) {
        self.axis = axis
        self.tracks = max(1, tracks)
        self.count = max(0, count)
        self.spacing = max(0, spacing)
        self.length = length
        self.viewport = viewport
    }

    var crossViewport: Double { axis.crossLength(viewport) }
    var mainViewport: Double { axis.mainLength(viewport) }

    /// Item length across the scrolling axis (the width of a column in a vertical grid).
    var crossExtent: Double {
        max(0, (crossViewport - spacing * Double(tracks - 1)) / Double(tracks))
    }

    /// Item length along the scrolling axis.
    var mainExtent: Double {
        switch length {
        case .fixed(let value): return max(0, value)
        case .aspect(let ratio):
            guard ratio > 0 else { return 0 }
            return axis == .vertical ? crossExtent / ratio : crossExtent * ratio
        }
    }

    var itemSize: Size { axis.size(main: mainExtent, cross: crossExtent) }
    var pitch: Double { mainExtent + spacing }
    var rowCount: Int { (count + tracks - 1) / tracks }
    var contentMain: Double { rowCount == 0 ? 0 : Double(rowCount) * pitch - spacing }
    var maxOffset: Double { max(0, contentMain - mainViewport) }

    func clamped(_ offset: Double) -> Double { min(max(0, offset), maxOffset) }

    /// Offset for an anchor item plus a fraction of a row, before clamping.
    func offset(anchorItem: Int, intra: Double) -> Double {
        Double(max(0, anchorItem) / tracks) * pitch + intra
    }

    /// The anchor that reproduces `offset`; the first item of the topmost partly visible row.
    func anchor(for offset: Double) -> (item: Int, intra: Double) {
        guard pitch > 0 else { return (0, 0) }
        let row = min(max(0, Int((offset / pitch).rounded(.down))), max(0, rowCount - 1))
        return (row * tracks, offset - Double(row) * pitch)
    }

    /// Rows that touch the viewport at `offset`.
    func visibleRows(at offset: Double) -> Range<Int> {
        guard rowCount > 0, pitch > 0, mainViewport > 0 else { return 0..<0 }
        let first = max(0, Int((offset / pitch).rounded(.down)))
        let last = min(rowCount, Int(((offset + mainViewport) / pitch).rounded(.up)))
        return first < last ? first..<last : 0..<0
    }

    /// Frame of `item` relative to the viewport origin at `offset`.
    func frame(of item: Int, offset: Double) -> Rect {
        let row = item / tracks, track = item % tracks
        let main = Double(row) * pitch - offset
        let cross = Double(track) * (crossExtent + spacing)
        return axis.rect(mainOrigin: main, mainLength: mainExtent, crossOrigin: cross, crossLength: crossExtent)
    }
}

/// A virtualized, scrolling grid: only the rows inside the viewport are built,
/// so a folder of 100 000 files costs what a screenful costs. Scrolls along
/// `axis` (use `.horizontal` for a filmstrip) and keeps its place by item
/// index, so a change of track count or axis keeps the same items in view.
///
/// `tracks` is the number of columns of a vertical grid or rows of a horizontal
/// one. `resetKey` returns the grid to the start whenever it changes (a new folder).
public struct LazyGrid<Content: XView>: XView {
    let axis: Axis
    let tracks: Int
    let count: Int
    let length: GridItemLength
    let spacing: Double
    let resetKey: String
    let content: @Sendable (Int, Size) -> Content

    public init(
        axis: Axis = .vertical,
        tracks: Int = 1,
        count: Int,
        length: GridItemLength,
        spacing: Double = 4,
        resetKey: String = "",
        @XViewBuilder content: @escaping @Sendable (_ index: Int, _ size: Size) -> Content
    ) {
        self.axis = axis
        self.tracks = tracks
        self.count = count
        self.length = length
        self.spacing = spacing
        self.resetKey = resetKey
        self.content = content
    }

    public var body: some XView {
        _LazyGridState(axis: axis, tracks: tracks, count: count, length: length,
                       spacing: spacing, resetKey: resetKey, content: content)
    }
}

@Stateful
private struct _LazyGridState<Content: XView>: XView {
    let axis: Axis
    let tracks: Int
    let count: Int
    let length: GridItemLength
    let spacing: Double
    let resetKey: String
    let content: @Sendable (Int, Size) -> Content
    @XState private var anchorItem: Int = 0
    @XState private var intra: Double = 0
    @XState private var lastKey: String = ""
    @XState private var lastTranslation: Double = 0

    init(axis: Axis, tracks: Int, count: Int, length: GridItemLength, spacing: Double,
         resetKey: String, content: @escaping @Sendable (Int, Size) -> Content) {
        self.axis = axis; self.tracks = tracks; self.count = count; self.length = length
        self.spacing = spacing; self.resetKey = resetKey; self.content = content
    }

    var body: some XView {
        let anchorBox = _anchorItem, intraBox = _intra, keyBox = _lastKey, translationBox = _lastTranslation
        let keyChanged = keyBox?.value != resetKey
        let axis = axis
        _LazyGridPrimitive(
            axis: axis, tracks: tracks, count: count, length: length, spacing: spacing, content: content,
            anchorItem: keyChanged ? 0 : anchorItem, intra: keyChanged ? 0 : intra,
            dragChanged: { translation in
                guard let intraBox, let translationBox else { return }
                intraBox.value -= translation - translationBox.value
                translationBox.value = translation
            },
            dragEnded: { translationBox?.value = 0 },
            normalize: { item, fraction in
                anchorBox?.value = item
                intraBox?.value = fraction
                keyBox?.value = resetKey
            }
        )
    }
}

private struct _LazyGridPrimitive<Content: XView>: XView, _PrimitiveXView {
    typealias Body = Never

    let axis: Axis
    let tracks: Int
    let count: Int
    let length: GridItemLength
    let spacing: Double
    let content: @Sendable (Int, Size) -> Content
    let anchorItem: Int
    let intra: Double
    let dragChanged: @Sendable (Double) -> Void
    let dragEnded: @Sendable () -> Void
    let normalize: @Sendable (Int, Double) -> Void

    @XUIActor
    func _lower(id stateID: StateIdentity, store: StateStore) async -> [LayoutNode] {
        let node = LayoutNode(layout: LazyGridLayout())
        node.clipsToBounds = true
        let axis = axis, dragChanged = dragChanged, dragEnded = dragEnded
        node.dragGesture = DragGesture(minimumDistance: 12)
            .onChanged { value in dragChanged(axis == .vertical ? value.translation.y : value.translation.x) }
            .onEnded { _ in dragEnded() }
        let (tracks, count, length, spacing, content) = (tracks, count, length, spacing, content)
        let (anchorItem, intra, normalize) = (anchorItem, intra, normalize)
        let contentType: Any.Type = Content.self
        let dragDrop = _EnvironmentObjectContext.currentOrEmpty.object(DragDropStore.self)
        node.lazyChildren = { rect, _ in
            let geometry = LazyGridGeometry(axis: axis, tracks: tracks, count: count, spacing: spacing,
                                            length: length, viewport: rect.size)
            var offset = geometry.clamped(geometry.offset(anchorItem: anchorItem, intra: intra))
            // A lifted view held near an edge scrolls the list under it.
            if let distance = dragDrop?.autoScrollDistance(in: rect, axis: axis), distance != 0 {
                offset = geometry.clamped(offset + distance)
            }
            let anchor = geometry.anchor(for: offset)
            if anchor.item != anchorItem || anchor.intra != intra { normalize(anchor.item, anchor.intra) }
            let rows = geometry.visibleRows(at: offset)
            guard !rows.isEmpty else { return [] }
            let itemSize = geometry.itemSize
            var cells: [LayoutNode] = []
            cells.reserveCapacity(rows.count * geometry.tracks)
            for row in rows {
                for track in 0..<geometry.tracks {
                    let item = row * geometry.tracks + track
                    if item >= geometry.count { break }
                    let cell = LayoutNode(
                        layout: PassthroughLayout(),
                        children: await lower(content(item, itemSize), id: stateID.child(type: contentType, index: item), store: store)
                    )
                    var frame = geometry.frame(of: item, offset: offset)
                    frame.x += rect.x
                    frame.y += rect.y
                    cell.frame = frame
                    cells.append(cell)
                }
            }
            return cells
        }
        return [node]
    }
}

/// Cells arrive with their frames already decided by the grid arithmetic.
struct LazyGridLayout: NodeLayout {
    func sizeThatFits(_ proposal: ProposedSize, _ children: [LayoutNode], _ context: LayoutContext) -> Size {
        proposal.resolved(fallback: Size(width: 10, height: 10))
    }

    func placeChildren(in rect: Rect, _ children: [LayoutNode], _ context: LayoutContext) {}
}
