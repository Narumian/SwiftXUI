import Foundation
import XUI
import XWorkspace

/// Supplies a ready-to-draw image for an item, or nil to show its type icon.
/// Called for visible items every frame, so it must be a cache lookup.
public typealias BrowserThumbnailProvider = @Sendable (BrowserItem) -> ImageSource?

enum Palette {
    // Neutral greys and a near-white accent: the surfaces and the accent used to be green. File-type colours are unchanged.
    static let background = XColorValue(hex: 0x181a1c)
    static let panel = XColorValue(hex: 0x26292c)
    static let selected = XColorValue(hex: 0x3a3e42)
    static let text = XColorValue(hex: 0xeaeced)
    static let muted = XColorValue(hex: 0xa6abae)
    static let accent = XColorValue(hex: 0xf0f2f3)

    static func color(_ category: FileCategory) -> XColorValue {
        switch category {
        case .folder: XColorValue(hex: 0xd9b45b)
        case .image: XColorValue(hex: 0x86b4d1)
        case .video: XColorValue(hex: 0xb486d1)
        case .audio: XColorValue(hex: 0xd18686)
        case .shader: XColorValue(hex: 0x86d1b5)
        case .laser: XColorValue(hex: 0x7ee08a)
        case .project: XColorValue(hex: 0xe0a07e)
        case .text: XColorValue(hex: 0xc4c8cc)
        default: XColorValue(hex: 0x868b90)   // other, and any category the host defined without a colour
        }
    }
}

/// A file browser that adapts to the box it is given: a one-line list in a narrow
/// tall panel, tiles in a squarish one, a horizontally scrolling filmstrip in a
/// short wide one, and a folder column beside the tiles when there is room.
public struct FileBrowserView: XView {
    let model: FileBrowserModel
    let policy: BrowserLayoutPolicy
    let thumbnail: BrowserThumbnailProvider?
    let onAddFolder: (@Sendable () -> Void)?
    let isDraggable: Bool

    /// `draggable` lets the files be lifted and dropped on a `.dropDestination(for: WorkspaceEntry.self)`;
    /// folders still only open. Off by default, so a browser that only picks keeps its press for scrolling.
    public init(model: FileBrowserModel, policy: BrowserLayoutPolicy = BrowserLayoutPolicy(),
                thumbnail: BrowserThumbnailProvider? = nil, onAddFolder: (@Sendable () -> Void)? = nil,
                draggable: Bool = false) {
        self.model = model
        self.policy = policy
        self.thumbnail = thumbnail
        self.onAddFolder = onAddFolder
        self.isDraggable = draggable
    }

    public var body: some XView {
        let model = model, policy = policy, thumbnail = thumbnail, onAddFolder = onAddFolder, isDraggable = isDraggable
        GeometryReader { geometry in
            let snapshot = model.snapshot()
            let layout = model.resolveLayout(policy, size: geometry.size)
            BrowserScene(model: model, snapshot: snapshot, layout: layout, size: geometry.size,
                         thumbnail: thumbnail, onAddFolder: onAddFolder, isDraggable: isDraggable)
        }
    }
}

struct BrowserScene: XView {
    let model: FileBrowserModel
    let snapshot: FileBrowserModel.Snapshot
    let layout: BrowserLayout
    let size: Size
    let thumbnail: BrowserThumbnailProvider?
    let onAddFolder: (@Sendable () -> Void)?
    let isDraggable: Bool

    var body: some XView {
        let gridSize = Size(width: max(0, size.width - layout.chromeWidth), height: max(0, size.height - layout.headerHeight))
        if layout.chrome == .leading {
            HStack(spacing: 0) {
                BrowserLeadingBar(model: model, snapshot: snapshot, width: layout.chromeWidth, height: size.height)
                grid(gridSize)
            }
        } else if layout.chrome == .sidebar {
            HStack(spacing: 0) {
                BrowserSidebar(model: model, snapshot: snapshot, width: layout.chromeWidth, height: size.height)
                VStack(spacing: 0) {
                    BrowserHeader(model: model, snapshot: snapshot, onAddFolder: onAddFolder).frame(width: gridSize.width, height: layout.headerHeight)
                    grid(gridSize)
                }
            }
        } else {
            VStack(spacing: 0) {
                BrowserHeader(model: model, snapshot: snapshot, onAddFolder: onAddFolder).frame(width: gridSize.width, height: layout.headerHeight)
                grid(gridSize)
            }
        }
    }

    private func grid(_ area: Size) -> some XView {
        let model = model, snapshot = snapshot, layout = layout, thumbnail = thumbnail, isDraggable = isDraggable
        let message = Self.message(snapshot)
        return ZStack {
            Color(Palette.background)
            LazyGrid(axis: layout.axis, tracks: layout.tracks, count: snapshot.visible.count, length: layout.itemLength,
                     spacing: layout.spacing, resetKey: snapshot.resetKey) { index, itemSize in
                BrowserCell(model: model, item: snapshot.item(atVisible: index), index: index, size: itemSize,
                            rows: layout.usesRows, selected: snapshot.selectedPath, thumbnail: thumbnail, isDraggable: isDraggable)
            }.padding(layout.spacing)
            if let message {
                Text(message, size: 13, color: Palette.muted)
            }
        }.frame(width: area.width, height: area.height)
    }

    static func message(_ snapshot: FileBrowserModel.Snapshot) -> String? {
        if let error = snapshot.error { return error }
        if snapshot.isLoading && snapshot.items.isEmpty { return "LOADING…" }
        if snapshot.visible.isEmpty { return snapshot.location == .roots ? "NO FOLDERS" : "EMPTY" }
        return nil
    }
}

struct BrowserHeader: XView {
    let model: FileBrowserModel
    let snapshot: FileBrowserModel.Snapshot
    let onAddFolder: (@Sendable () -> Void)?

    var body: some XView {
        let model = model
        if model.isSearching {
            searchRow(model)
        } else {
            titleRow(model)
        }
    }

    private func searchRow(_ model: FileBrowserModel) -> some XView {
        var style = TextFieldStyle()
        style.fontSize = 14
        style.verticalPadding = 7
        style.background = Palette.background
        style.border = Palette.selected
        style.focusedBorder = Palette.accent
        style.caret = Palette.accent
        style.selection = Palette.accent.opacity(0.3)
        style.textColor = Palette.text
        style.placeholderColor = Palette.muted
        style.cornerRadius = 8
        return HStack(spacing: 8) {
            TextField("Search \(snapshot.title)", text: Binding(get: { model.queryText }, set: { model.setQuery($0) }),
                      id: "browser.search", returnKey: .search, style: style, autofocus: true)
            Text("\(snapshot.visible.count)", size: 12, color: Palette.muted)
            Text("DONE", size: 13, color: Palette.background).padding(10)
                .background { RoundedRectangle(cornerRadius: 8, fill: Palette.accent) }
                .onTapGesture(id: "browser.search.close", label: "Close search") { model.setSearching(false) }
        }.padding(8).background { Rectangle(fill: Palette.panel) }
    }

    private func titleRow(_ model: FileBrowserModel) -> some XView {
        let add = onAddFolder
        return HStack(spacing: 8) {
            if snapshot.canGoUp {
                Text("‹", size: 22, color: Palette.text).frame(width: 36, height: 36)
                    .background { RoundedRectangle(cornerRadius: 8, fill: Palette.panel) }
                    .onTapGesture(id: "browser.up", label: "Up") { model.goUp() }
            }
            Text(snapshot.title, size: 14, color: Palette.text).lineLimit(1)
            Spacer()
            Text("\(snapshot.visible.count)", size: 12, color: Palette.muted)
            if snapshot.location != .roots {
                Text("SEARCH", size: 12, color: Palette.text).padding(10)
                    .background { RoundedRectangle(cornerRadius: 8, fill: Palette.selected) }
                    .onTapGesture(id: "browser.search.open", label: "Search") { model.setSearching(true) }
            }
            if snapshot.choosesFolders, snapshot.canGoUp {
                Text("OPEN", size: 13, color: Palette.background).padding(10)
                    .background { RoundedRectangle(cornerRadius: 8, fill: Palette.accent) }
                    .onTapGesture(id: "browser.choose", label: "Open this folder") { model.chooseCurrentFolder() }
            }
            if let add, snapshot.location == .roots {
                Text("+", size: 22, color: Palette.accent).frame(width: 36, height: 36)
                    .background { RoundedRectangle(cornerRadius: 8, fill: Palette.panel) }
                    .onTapGesture(id: "browser.add", label: "Add folder") { add() }
            }
        }.padding(8).background { Rectangle(fill: Palette.panel) }
    }
}

struct BrowserLeadingBar: XView {
    let model: FileBrowserModel
    let snapshot: FileBrowserModel.Snapshot
    let width: Double
    let height: Double

    var body: some XView {
        let model = model
        VStack(spacing: 8) {
            if snapshot.canGoUp {
                Text("‹", size: 22, color: Palette.text).frame(width: 44, height: 44)
                    .background { RoundedRectangle(cornerRadius: 8, fill: Palette.selected) }
                    .onTapGesture(id: "browser.up", label: "Up") { model.goUp() }
            }
            Text(snapshot.title, size: 11, color: Palette.text).lineLimit(2).frame(width: 60)
            Spacer()
            Text("\(snapshot.visible.count)", size: 11, color: Palette.muted)
        }.padding(6)
            .frame(width: width, height: height, alignment: .top)
            .background { Rectangle(fill: Palette.panel) }
    }
}

struct BrowserSidebar: XView {
    let model: FileBrowserModel
    let snapshot: FileBrowserModel.Snapshot
    let width: Double
    let height: Double

    var body: some XView {
        let model = model
        let current: UUID? = { if case .folder(let id, _) = snapshot.location { id } else { nil } }()
        VStack(alignment: .leading, spacing: 4) {
            Text("FOLDERS", size: 11, color: Palette.muted).padding(6)
            ForEach(snapshot.folders) { folder in
                Text(folder.name, size: 13, color: Palette.text).lineLimit(1).padding(8)
                    .frame(width: max(0, width - 16), alignment: .leading)
                    .background { RoundedRectangle(cornerRadius: 6, fill: folder.id == current ? Palette.selected : Palette.panel) }
                    .onTapGesture(id: "browser.root.\(folder.id)", label: folder.name) { model.open(.folder(id: folder.id, path: "")) }
            }
            Spacer()
        }.padding(8)
            .frame(width: width, height: height, alignment: .topLeading)
            .background { Rectangle(fill: Palette.panel) }
    }
}

/// One tile or row, painted by a single draw callback: a folder of 100 000 files
/// still shows ~60 cells per frame, so the per-cell node count is what a frame costs.
struct BrowserCell: XView {
    let model: FileBrowserModel
    let item: BrowserItem?
    let index: Int
    let size: Size
    let rows: Bool
    let selected: String?
    let thumbnail: BrowserThumbnailProvider?
    let isDraggable: Bool

    var body: some XView {
        if let item {
            let model = model, index = index, size = size, rows = rows
            let types = model.fileTypes
            let isSelected = selected == item.path && !item.isDirectory
            let image = thumbnail?(item)
            let cell = DrawLayer(size: { _ in size }) { rect, context in
                BrowserCell.paint(item, image: image, selected: isSelected, rows: rows, types: types, in: rect, context: context)
            }.onTapGesture(id: "browser.item", label: item.name) { model.activate(visibleIndex: index) }
            if isDraggable, !item.isDirectory {
                cell.draggable(item.entry, cornerRadius: 8, id: item.path)
            } else {
                cell
            }
        }
    }

    static func paint(_ item: BrowserItem, image: ImageSource?, selected: Bool, rows: Bool, types: FileTypes, in rect: Rect, context: RenderContext) {
        let canvas = context.canvas
        canvas.fillRoundedRect(rect, cornerRadius: 8, color: selected ? Palette.selected : Palette.panel)
        let measure = context.environment.measureText
        if rows {
            let side = max(0, min(rect.height - 12, 40))
            let iconRect = Rect(x: rect.x + 6, y: rect.y + (rect.height - side) / 2, width: side, height: side)
            paintIcon(item, image: image, types: types, in: iconRect, canvas: canvas, measure: measure)
            var right = rect.x + rect.width - 8
            if let detail = detail(item) {
                let width = BrowserTextFit.shared.width(detail, size: 11, context: context)
                canvas.drawText(detail, in: Rect(x: right - width, y: rect.y + (rect.height - 14) / 2, width: width, height: 14),
                                fontSize: 11, font: .ui, color: Palette.muted, alignment: .trailing, outline: nil)
                right -= width + 8
            }
            let left = iconRect.x + side + 10
            let name = BrowserTextFit.shared.fit(item.name, size: 13, maxWidth: max(0, right - left), middle: !item.isDirectory, context: context)
            canvas.drawText(name, in: Rect(x: left, y: rect.y + (rect.height - 16) / 2, width: max(0, right - left), height: 16),
                            fontSize: 13, font: .ui, color: Palette.text, alignment: .leading, outline: nil)
        } else {
            let side = max(0, min(rect.width - 16, rect.height - 34))
            let iconRect = Rect(x: rect.x + (rect.width - side) / 2, y: rect.y + 6, width: side, height: side)
            paintIcon(item, image: image, types: types, in: iconRect, canvas: canvas, measure: measure)
            let width = max(0, rect.width - 12)
            let name = BrowserTextFit.shared.fit(item.name, size: 11, maxWidth: width, middle: !item.isDirectory, context: context)
            canvas.drawText(name, in: Rect(x: rect.x + 6, y: iconRect.y + side + 4, width: width, height: 14),
                            fontSize: 11, font: .ui, color: Palette.text, alignment: .center, outline: nil)
        }
    }

    private static func paintIcon(_ item: BrowserItem, image: ImageSource?, types: FileTypes, in rect: Rect, canvas: any XCanvas,
                                  measure: (String, Double, TextFont) -> Size) {
        guard rect.width > 0, rect.height > 0 else { return }
        if let image, image.naturalSize.width > 0, image.naturalSize.height > 0 {
            let scale = min(rect.width / image.naturalSize.width, rect.height / image.naturalSize.height)
            let fitted = Size(width: image.naturalSize.width * scale, height: image.naturalSize.height * scale)
            canvas.drawImage(image, in: Rect(x: rect.x + (rect.width - fitted.width) / 2, y: rect.y + (rect.height - fitted.height) / 2,
                                             width: fitted.width, height: fitted.height), opacity: 1)
            return
        }
        canvas.fillRoundedRect(rect, cornerRadius: 6, color: types.color(for: item.category))
        if item.isDirectory {
            // Drawn as a shape: the bundled font has no folder symbol.
            let g = rect.width * 0.5, h = g * 0.72
            let x = rect.midX - g / 2, y = rect.midY - h / 2
            let points = [Point(x: x, y: y), Point(x: x + g * 0.4, y: y), Point(x: x + g * 0.5, y: y + h * 0.2),
                          Point(x: x + g, y: y + h * 0.2), Point(x: x + g, y: y + h), Point(x: x, y: y + h)]
            canvas.fillPath(Path(points: points), in: Rect(x: x, y: y, width: g, height: h), color: Palette.background)
            return
        }
        let badge = item.badge
        let fontSize = max(9, min(14, rect.width * 0.3))
        canvas.drawText(badge, in: Rect(x: rect.x, y: rect.y + (rect.height - fontSize * 1.2) / 2, width: rect.width, height: fontSize * 1.2),
                        fontSize: fontSize, font: .ui, color: Palette.background, alignment: .center, outline: nil)
    }

    static func detail(_ item: BrowserItem) -> String? {
        guard !item.isDirectory, let bytes = item.entry.size else { return nil }
        if bytes < 1_000 { return "\(bytes) B" }
        if bytes < 1_000_000 { return "\(bytes / 1_000) KB" }
        if bytes < 1_000_000_000 { return "\(bytes / 1_000_000) MB" }
        return "\(bytes / 1_000_000_000) GB"
    }
}
