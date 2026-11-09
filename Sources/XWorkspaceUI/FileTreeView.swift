import Foundation
import XUI
import XWorkspace

extension WorkspaceEntry: XTransferable {}

/// Folders and files as an outline, like the project navigator in an IDE: a disclosure
/// triangle opens a folder in place, children are indented under it, and the rows scroll
/// lazily, so only the ones on screen cost anything.
public struct FileTreeView: XView {
    let model: FileTreeModel
    let rowHeight: Double
    let indent: Double

    public init(model: FileTreeModel, rowHeight: Double = 30, indent: Double = 16) {
        self.model = model
        self.rowHeight = rowHeight
        self.indent = indent
    }

    public var body: some XView {
        let model = model, rowHeight = rowHeight, indent = indent
        GeometryReader { geometry in
            let snapshot = model.snapshot()
            let area = geometry.size
            ZStack {
                Color(Palette.background)
                LazyGrid(axis: .vertical, tracks: 1, count: snapshot.rows.count, length: .fixed(rowHeight),
                         spacing: 0, resetKey: "") { index, size in
                    FileTreeRow(model: model, row: snapshot.rows.indices.contains(index) ? snapshot.rows[index] : nil,
                                index: index, size: size, indent: indent, selected: snapshot.selected,
                                dropTarget: snapshot.dropTarget)
                }
                if snapshot.rows.isEmpty {
                    Text(snapshot.error ?? "NO FOLDERS", size: 13, color: Palette.muted)
                }
            }.frame(width: area.width, height: area.height)
        }
    }
}

/// One outline row, painted by a single draw callback.
struct FileTreeRow: XView {
    let model: FileTreeModel
    let row: FileTreeModel.Row?
    let index: Int
    let size: Size
    let indent: Double
    let selected: FileTreeModel.NodeKey?
    let dropTarget: FileTreeModel.NodeKey?

    var body: some XView {
        if let row {
            let model = model, index = index, size = size, indent = indent
            let key = row.key
            let entry = row.item.entry
            let isSelected = selected == key
            let isTarget = dropTarget == key
            DrawLayer(size: { _ in size }) { rect, context in
                FileTreeRow.paint(row, selected: isSelected, targeted: isTarget, indent: indent, in: rect, context: context)
            }
            .onTapGesture(id: "tree.row", label: row.item.name) { model.activate(row: index) }
            .draggable(entry, cornerRadius: 6, id: key)
            .contextMenu { model.contextMenu?(entry) ?? [] }
            .dropDestination(for: WorkspaceEntry.self,
                             isValid: { row.item.isDirectory && model.accepts($0, on: key) },
                             springLoaded: row.item.isDirectory && !row.isExpanded ? (delay: 0.7, action: { model.expand(key) }) : nil,
                             isTargeted: { model.setDropTarget(key, $0) }) { items, _ in
                model.drop(items[0], on: key)
            }
        }
    }

    static func paint(_ row: FileTreeModel.Row, selected: Bool, targeted: Bool, indent: Double, in rect: Rect, context: RenderContext) {
        let canvas = context.canvas
        if targeted {
            let box = Rect(x: rect.x + 4, y: rect.y + 1, width: rect.width - 8, height: rect.height - 2)
            canvas.fillRoundedRect(box, cornerRadius: 6, color: Palette.accent.opacity(0.14))
            canvas.strokeRoundedRect(box, cornerRadius: 6, color: Palette.accent, lineWidth: 1.5)
        }
        if selected { canvas.fillRoundedRect(Rect(x: rect.x + 4, y: rect.y + 1, width: rect.width - 8, height: rect.height - 2),
                                             cornerRadius: 6, color: Palette.selected) }
        // Deep trees squeeze their steps instead of pushing the names out of the box.
        let step = min(indent, max(4, (rect.width - 140) / Double(max(1, row.depth))))
        let cy = rect.y + rect.height / 2
        let triangle = 18.0
        let left = rect.x + 10 + Double(row.depth) * step

        if row.item.isDirectory {
            let cx = left + triangle / 2
            let points = row.isExpanded
                ? [Point(x: cx - 4.5, y: cy - 2.5), Point(x: cx + 4.5, y: cy - 2.5), Point(x: cx, y: cy + 3.5)]
                : [Point(x: cx - 2.5, y: cy - 4.5), Point(x: cx + 3.5, y: cy), Point(x: cx - 2.5, y: cy + 4.5)]
            canvas.fillPath(Path(points: points), in: Rect(x: cx - 5, y: cy - 5, width: 10, height: 10),
                            color: row.isLoading ? Palette.accent : Palette.muted)
        }

        let icon = rect.height * 0.5
        let iconRect = Rect(x: left + triangle + 2, y: cy - icon / 2, width: icon, height: icon)
        paintIcon(row.item, in: iconRect, canvas: canvas)

        let textLeft = iconRect.x + icon + 8
        let width = max(0, rect.x + rect.width - 10 - textLeft)
        let name = BrowserTextFit.shared.fit(row.item.name, size: 13, maxWidth: width, middle: !row.item.isDirectory, context: context)
        canvas.drawText(name, in: Rect(x: textLeft, y: cy - 8, width: width, height: 16),
                        fontSize: 13, font: .ui, color: Palette.text, alignment: .leading, outline: nil)
    }

    private static func paintIcon(_ item: BrowserItem, in rect: Rect, canvas: any XCanvas) {
        let color = Palette.color(item.category)
        if item.isDirectory {
            // A folder: a tab and a body, drawn as shapes (the bundled font has no folder symbol).
            let tab = [Point(x: rect.x, y: rect.y + rect.height * 0.18), Point(x: rect.x + rect.width * 0.42, y: rect.y + rect.height * 0.18),
                       Point(x: rect.x + rect.width * 0.55, y: rect.y + rect.height * 0.3), Point(x: rect.x, y: rect.y + rect.height * 0.3)]
            canvas.fillPath(Path(points: tab), in: rect, color: color)
            canvas.fillRoundedRect(Rect(x: rect.x, y: rect.y + rect.height * 0.28, width: rect.width, height: rect.height * 0.58),
                                   cornerRadius: 2.5, color: color)
        } else {
            // A page.
            canvas.fillRoundedRect(Rect(x: rect.x + rect.width * 0.1, y: rect.y, width: rect.width * 0.8, height: rect.height),
                                   cornerRadius: 2.5, color: color)
        }
    }
}
