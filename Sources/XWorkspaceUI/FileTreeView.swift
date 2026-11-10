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
    let onAddFolder: (@Sendable () -> Void)?
    let isSearchable: Bool
    let keyFocusID: String

    /// - Parameters:
    ///   - onAddFolder: when set, the bar under the tree has a `+` that calls it (a project navigator's add button).
    ///   - searchable: puts a filter field in that bar; typing narrows the tree to the matching names and the folders above them.
    ///   - keyFocusID: the key focus area of the tree. A press in the tree aims the keyboard at it, and then the arrow keys
    ///     move the selection (Up, Down, Home, End), Left and Right close and open folders, and Return loads or toggles.
    ///     Give each tree on one screen its own id.
    public init(model: FileTreeModel, rowHeight: Double = 26, indent: Double = 14,
                onAddFolder: (@Sendable () -> Void)? = nil, searchable: Bool = false, keyFocusID: String = "file.tree") {
        self.model = model
        self.rowHeight = rowHeight
        self.indent = indent
        self.onAddFolder = onAddFolder
        self.isSearchable = searchable
        self.keyFocusID = keyFocusID
    }

    public var body: some XView {
        let model = model, rowHeight = rowHeight, indent = indent, add = onAddFolder, searchable = isSearchable, focusID = keyFocusID
        KeyFocusReader { focusedID in
            GeometryReader { geometry in
                let snapshot = model.snapshot()
                let area = geometry.size
                let isFocused = focusedID == focusID
                let hasBar = add != nil || searchable
                let barHeight = hasBar ? 38.0 : 0.0
                let listHeight = max(0, area.height - barHeight)
                VStack(spacing: 0) {
                    ZStack {
                        Color(Palette.background)
                        LazyGrid(axis: .vertical, tracks: 1, count: snapshot.rows.count, length: .fixed(rowHeight),
                                 spacing: 0, resetKey: "", reveal: snapshot.reveal) { index, size in
                            FileTreeRow(model: model, row: snapshot.rows.indices.contains(index) ? snapshot.rows[index] : nil,
                                        index: index, size: size, indent: indent, selected: snapshot.selected,
                                        dropTarget: snapshot.dropTarget, keyFocused: isFocused)
                        }
                        if snapshot.rows.isEmpty {
                            Text(snapshot.error ?? (snapshot.query.isEmpty ? "NO FOLDERS" : "NO MATCHES"), size: 13, color: Palette.muted)
                        }
                    }.frame(width: area.width, height: listHeight)
                        .keyFocusArea(id: focusID)
                        .keyboardShortcut(.upArrow, focusID: focusID) { model.moveSelection(by: -1) }
                        .keyboardShortcut(.downArrow, focusID: focusID) { model.moveSelection(by: 1) }
                        .keyboardShortcut(.home, focusID: focusID) { model.moveSelection(toLast: false) }
                        .keyboardShortcut(.end, focusID: focusID) { model.moveSelection(toLast: true) }
                        .keyboardShortcut(.leftArrow, focusID: focusID) { model.collapseOrSelectParent() }
                        .keyboardShortcut(.rightArrow, focusID: focusID) { model.expandOrSelectFirstChild() }
                        .keyboardShortcut(.returnKey, focusID: focusID) { model.activateSelected() }
                    if hasBar { Self.bar(model: model, add: add, searchable: searchable).frame(width: area.width, height: barHeight) }
                }.frame(width: area.width, height: area.height, alignment: .top)
            }
        }
    }

    /// The bar under the tree: add a folder, and filter by name.
    private static func bar(model: FileTreeModel, add: (@Sendable () -> Void)?, searchable: Bool) -> some XView {
        var style = TextFieldStyle()
        style.fontSize = 13
        style.verticalPadding = 5
        style.background = Palette.background
        style.border = Palette.selected
        style.focusedBorder = Palette.accent
        style.caret = Palette.accent
        style.selection = Palette.accent.opacity(0.3)
        style.textColor = Palette.text
        style.placeholderColor = Palette.muted
        style.cornerRadius = 6
        return HStack(spacing: 6) {
            if let add {
                Text("+", size: 20, color: Palette.accent).frame(width: 28, height: 28)
                    .background { RoundedRectangle(cornerRadius: 6, fill: Palette.selected) }
                    .onTapGesture(id: "tree.add", label: "Add folder") { add() }
            }
            if searchable {
                TextField("Filter", text: Binding(get: { model.queryText }, set: { model.setQuery($0) }),
                          id: "tree.filter", returnKey: .search, style: style)
            } else {
                Spacer()
            }
        }.padding(5).background { Rectangle(fill: Palette.panel) }
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
    /// Whether the keyboard is aimed at the tree: the selection is then drawn in the accent colour, like a focused source list.
    let keyFocused: Bool

    var body: some XView {
        if let row {
            let model = model, index = index, size = size, indent = indent
            let types = model.fileTypes
            let key = row.key
            let entry = row.item.entry
            let isSelected = selected == key
            let isTarget = dropTarget == key
            let keyFocused = keyFocused
            DrawLayer(size: { _ in size }) { rect, context in
                FileTreeRow.paint(row, selected: isSelected, focused: keyFocused, targeted: isTarget, indent: indent, types: types, in: rect, context: context)
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

    static func paint(_ row: FileTreeModel.Row, selected: Bool, focused: Bool, targeted: Bool, indent: Double, types: FileTypes, in rect: Rect, context: RenderContext) {
        let canvas = context.canvas
        if targeted {
            let box = Rect(x: rect.x + 4, y: rect.y + 1, width: rect.width - 8, height: rect.height - 2)
            canvas.fillRoundedRect(box, cornerRadius: 6, color: Palette.accent.opacity(0.14))
            canvas.strokeRoundedRect(box, cornerRadius: 6, color: Palette.accent, lineWidth: 1.5)
        }
        let onAccent = selected && focused
        if selected { canvas.fillRoundedRect(Rect(x: rect.x + 4, y: rect.y + 1, width: rect.width - 8, height: rect.height - 2),
                                             cornerRadius: 6, color: onAccent ? focusedSelection : Palette.selected) }
        // Deep trees squeeze their steps instead of pushing the names out of the box.
        let step = min(indent, max(4, (rect.width - 140) / Double(max(1, row.depth))))
        let cy = rect.y + rect.height / 2
        let triangle = 18.0
        let left = rect.x + 10 + Double(row.depth) * step

        if row.item.isDirectory {
            paintChevron(open: row.isExpanded, at: Point(x: left + triangle / 2, y: cy),
                         color: row.isLoading ? Palette.accent : (onAccent ? Palette.text : Palette.muted), canvas: canvas)
        }

        let icon = rect.height * 0.6
        let iconRect = Rect(x: left + triangle + 2, y: cy - icon / 2, width: icon, height: icon)
        paintIcon(row.item, types: types, in: iconRect, canvas: canvas)

        let textLeft = iconRect.x + icon + 8
        let width = max(0, rect.x + rect.width - 10 - textLeft)
        let name = BrowserTextFit.shared.fit(row.item.name, size: 13, maxWidth: width, middle: !row.item.isDirectory, context: context)
        canvas.drawText(name, in: Rect(x: textLeft, y: cy - 8, width: width, height: 16),
                        fontSize: 13, font: .ui, color: Palette.text, alignment: .leading, outline: nil)
    }

    /// The selection of a tree the keyboard is aimed at.
    private static let focusedSelection = XColorValue(hex: 0x2e5f9e)

    /// The disclosure chevron of a source list: a thick, round-ended `>` that turns to point down when the folder is open
    /// (the way the system draws `chevron.right`). The canvas strokes with square ends, so each end and the corner get a dot.
    private static func paintChevron(open: Bool, at center: Point, color: XColorValue, canvas: any XCanvas) {
        let width = 1.9
        // Right-pointing: tip on the right. Open: the same chevron turned a quarter, tip down.
        let corners = open
            ? [Point(x: center.x - 3.6, y: center.y - 1.9), Point(x: center.x, y: center.y + 2.1), Point(x: center.x + 3.6, y: center.y - 1.9)]
            : [Point(x: center.x - 1.9, y: center.y - 3.6), Point(x: center.x + 2.1, y: center.y), Point(x: center.x - 1.9, y: center.y + 3.6)]
        let box = Rect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
        canvas.strokePath(Path(points: corners, closed: false), in: box, color: color, lineWidth: width)
        for point in corners {
            canvas.fillEllipse(in: Rect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width), color: color)
        }
    }

    private static func paintIcon(_ item: BrowserItem, types: FileTypes, in rect: Rect, canvas: any XCanvas) {
        let color = types.color(for: item.category)
        if item.isDirectory {
            // A folder: a tab and a body, drawn as shapes (the bundled font has no folder symbol).
            let tab = [Point(x: rect.x, y: rect.y + rect.height * 0.18), Point(x: rect.x + rect.width * 0.42, y: rect.y + rect.height * 0.18),
                       Point(x: rect.x + rect.width * 0.55, y: rect.y + rect.height * 0.3), Point(x: rect.x, y: rect.y + rect.height * 0.3)]
            canvas.fillPath(Path(points: tab), in: rect, color: color)
            canvas.fillRoundedRect(Rect(x: rect.x, y: rect.y + rect.height * 0.28, width: rect.width, height: rect.height * 0.58),
                                   cornerRadius: 2.5, color: color)
        } else {
            // A page with a turned corner.
            let left = rect.x + rect.width * 0.15, right = rect.x + rect.width * 0.85
            let fold = rect.width * 0.28
            let page = [Point(x: left, y: rect.y), Point(x: right - fold, y: rect.y), Point(x: right, y: rect.y + fold),
                        Point(x: right, y: rect.y + rect.height), Point(x: left, y: rect.y + rect.height)]
            canvas.fillPath(Path(points: page), in: rect, color: color)
        }
    }
}
