import Foundation
import XUI
import XWorkspace

/// The state behind an outline of folders and files, like a project navigator.
///
/// Folders load the first time they open and stay cached; the tree is flattened into
/// rows once per change, so a frame only reads `Snapshot.rows`.
public final class FileTreeModel: @unchecked Sendable {
    /// A folder or file, identified across folders.
    public struct NodeKey: Codable, Hashable, Sendable {
        public var folderID: UUID
        public var path: String
        public init(folderID: UUID, path: String) { self.folderID = folderID; self.path = path }
    }

    public struct Row: Sendable {
        public let item: BrowserItem
        public let depth: Int
        public let isExpanded: Bool
        public let isLoading: Bool
        public var key: NodeKey { NodeKey(folderID: item.entry.folderID, path: item.entry.path) }
    }

    public struct Snapshot: Sendable {
        public var rows: [Row] = []
        public var selected: NodeKey?
        /// The folder a drag is hovering over.
        public var dropTarget: NodeKey?
        public var error: String?
        /// The text the names are filtered by; empty shows the whole tree.
        public var query = ""
        /// The row the keyboard moved the selection to, for the view to scroll into sight.
        public var reveal: GridReveal?
        /// Bumps whenever `rows` change.
        public var generation = 0
    }

    private let workspace: Workspace
    private let only: UUID?
    private let expansionPersistenceKey: String?
    private let invalidate: @Sendable () -> Void
    private let lock = NSLock()

    private var filter: BrowserFilter
    /// Which category each extension is, and how it is drawn.
    public let fileTypes: FileTypes
    private var roots: [BrowserItem] = []
    private var children: [NodeKey: [BrowserItem]] = [:]
    private var expanded: Set<NodeKey> = []
    private var loading: Set<NodeKey> = []
    private var state = Snapshot()
    private var pick: (@Sendable (WorkspaceEntry) -> Void)?
    private var load: (@Sendable (WorkspaceEntry) -> Void)?
    private var lastActivation: (key: NodeKey, time: TimeInterval)?
    private var revealToken = 0
    /// The registered folders as last listed, and the modification stamp of every folder that is loaded: what `refreshIfChanged` compares.
    private var knownFolders: [WorkspaceFolder] = []
    private var stamps: [NodeKey: WorkspaceStamp] = [:]
    private var watcher: Task<Void, Never>?
    /// The most folders a search lists on its own to find matches below folders that were never opened.
    private static let searchFolderLimit = 400

    deinit { watcher?.cancel() }

    /// - Parameter folderID: show just this registered folder as the root; nil shows every registered folder.
    public init(workspace: Workspace, folderID: UUID? = nil, filter: BrowserFilter = .all, fileTypes: FileTypes = .standard,
                expansionPersistenceKey: String? = nil,
                invalidate: @escaping @Sendable () -> Void = {}) {
        self.workspace = workspace
        self.fileTypes = fileTypes
        self.only = folderID
        self.filter = filter
        self.expansionPersistenceKey = expansionPersistenceKey
        if let expansionPersistenceKey,
           let data = UserDefaults.standard.data(forKey: expansionPersistenceKey),
           let saved = try? JSONDecoder().decode([NodeKey].self, from: data) {
            expanded = Set(saved)
        }
        self.invalidate = invalidate
    }

    /// Called when something dragged from the tree lands on a folder. Return whether it was taken; the model
    /// reloads afterwards. Without it, folders do not accept drops.
    public var onDrop: (@Sendable (_ entry: WorkspaceEntry, _ destination: NodeKey) -> Bool)? {
        get { lock.withLock { drop } }
        set { lock.withLock { drop = newValue } }
    }
    private var drop: (@Sendable (WorkspaceEntry, NodeKey) -> Bool)?

    /// Lets a drop move the file or folder into the target folder on disk (`Workspace.move`). The drop is taken at once
    /// and the tree reloads when the move is done; a failure goes to `onError`. Ignored when `onDrop` is set.
    public var movesOnDrop: Bool {
        get { lock.withLock { moves } }
        set { lock.withLock { moves = newValue } }
    }
    private var moves = false

    /// Told why a move failed (a name already there, a read-only folder).
    public var onError: (@Sendable (String) -> Void)? {
        get { lock.withLock { failed } }
        set { lock.withLock { failed = newValue } }
    }
    private var failed: (@Sendable (String) -> Void)?

    /// The context menu for a row (a secondary click, or a row lifted and released in place). Empty means none.
    public var contextMenu: (@Sendable (WorkspaceEntry) -> [ContextMenuItem])? {
        get { lock.withLock { menu } }
        set { lock.withLock { menu = newValue } }
    }
    private var menu: (@Sendable (WorkspaceEntry) -> [ContextMenuItem])?

    /// Called when a file (not a folder) is chosen.
    public var onPick: (@Sendable (WorkspaceEntry) -> Void)? {
        get { lock.withLock { pick } }
        set { lock.withLock { pick = newValue } }
    }

    /// Called when the same file is chosen twice in quick succession (a double click or double tap), in place of
    /// `onPick` the second time. Without it, a second choice picks again.
    public var onLoad: (@Sendable (WorkspaceEntry) -> Void)? {
        get { lock.withLock { load } }
        set { lock.withLock { load = newValue } }
    }

    /// How long after one choice a second one counts as a double.
    public var doubleActivationInterval: TimeInterval = 0.4

    public func snapshot() -> Snapshot { lock.withLock { state } }

    // MARK: - Loading

    /// Lists the roots again, and every open folder under them.
    public func reload() async {
        let folders = await workspace.folders().filter { only == nil || $0.id == only }
        let items = folders.map { BrowserItem(entry: WorkspaceEntry(folderID: $0.id, path: "", kind: .directory), displayName: $0.name) }
        let open = lock.withLock { expanded }
        lock.withLock {
            knownFolders = folders
            roots = items
            // A lone root opens by itself, as a project does.
            if only != nil, let root = items.first, state.rows.isEmpty { expanded.insert(Self.key(root)) }
        }
        // While a name is searched for, every folder already listed is listed again too.
        let wanted = lock.withLock { expanded.union(open).union(state.query.isEmpty ? [] : Set(children.keys)) }
        for key in wanted.sorted(by: { $0.path.count < $1.path.count }) { await loadChildren(of: key) }
        // Folders that are shut are listed again when they next open, not from a listing that may be stale.
        lock.withLock {
            if state.query.isEmpty { children = children.filter { expanded.contains($0.key) } }
            stamps = stamps.filter { children[$0.key] != nil }
        }
        rebuild()
    }

    private func loadChildren(of key: NodeKey) async {
        lock.withLock { _ = loading.insert(key) }
        var listed: [BrowserItem]?
        var failure: String?
        var stamp: WorkspaceStamp?
        do {
            stamp = try? await workspace.directoryStamp(folderID: key.folderID, path: key.path)
            let entries = try await workspace.list(folderID: key.folderID, path: key.path, sorted: false)
            let filter = lock.withLock { self.filter }
            let items = entries.map { BrowserItem(entry: $0, types: fileTypes) }.filter { filter.admits($0) }
            listed = await Task.detached(priority: .userInitiated) { BrowserOrdering.sorted(items) }.value
        } catch {
            failure = (error as NSError).localizedDescription
        }
        lock.withLock {
            loading.remove(key)
            if let listed { children[key] = listed; stamps[key] = stamp; state.error = nil }
            else { expanded.remove(key); state.error = failure }
        }
    }

    // MARK: - Interaction

    /// Opens or closes a folder row; selects and picks a file row, and loads it when it is chosen twice in a row.
    /// While a name is searched for the folders stay open, so a folder row is only selected.
    public func activate(row index: Int, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let (row, pick, load, searching) = lock.withLock {
            (state.rows.indices.contains(index) ? state.rows[index] : nil, self.pick, self.load, !state.query.isEmpty)
        }
        guard let row else { return }
        if row.item.isDirectory {
            lock.withLock { state.selected = row.key }
            if searching { rebuild() } else { row.isExpanded ? collapse(row.key) : expand(row.key) }
        } else {
            let isDouble = lock.withLock { () -> Bool in
                let double = lastActivation.map { $0.key == row.key && now - $0.time <= doubleActivationInterval } ?? false
                state.selected = row.key
                lastActivation = double ? nil : (row.key, now)
                return double
            }
            rebuild()
            if isDouble, let load { load(row.item.entry) } else { pick?(row.item.entry) }
        }
    }

    // MARK: - Keyboard

    /// Index of the selected row among the rows shown; nil when nothing is selected or it is filtered away. Caller holds the lock.
    private var selectedIndex: Int? {
        guard let key = state.selected else { return nil }
        return state.rows.firstIndex { $0.key == key }
    }

    /// Selects a row and asks the view to scroll to it. Selecting does not pick: moving over files with the keys must
    /// not import them.
    private func select(rowAt index: Int) {
        lock.withLock {
            guard state.rows.indices.contains(index) else { return }
            state.selected = state.rows[index].key
            revealToken += 1
            state.reveal = GridReveal(item: index, token: revealToken)
        }
        invalidate()
    }

    /// Moves the selection by `delta` rows (the arrow keys), stopping at the ends. With nothing selected, down starts
    /// at the first row and up at the last.
    public func moveSelection(by delta: Int) {
        let target = lock.withLock { () -> Int? in
            guard !state.rows.isEmpty else { return nil }
            guard let current = selectedIndex else { return delta >= 0 ? 0 : state.rows.count - 1 }
            return min(max(0, current + delta), state.rows.count - 1)
        }
        if let target { select(rowAt: target) }
    }

    /// Selects the first or the last row (Home, End).
    public func moveSelection(toLast last: Bool) {
        let target = lock.withLock { state.rows.isEmpty ? nil : (last ? state.rows.count - 1 : 0) }
        if let target { select(rowAt: target) }
    }

    /// Left arrow: closes the selected folder; on a file or a closed folder it selects the folder above.
    public func collapseOrSelectParent() {
        let (row, index, searching) = lock.withLock { () -> (Row?, Int?, Bool) in
            let index = selectedIndex
            return (index.map { state.rows[$0] }, index, !state.query.isEmpty)
        }
        guard let row, let index else { return }
        if row.item.isDirectory, row.isExpanded, !searching { collapse(row.key); return }
        if let parent = lock.withLock({ state.rows[..<index].lastIndex { $0.depth < row.depth } }) { select(rowAt: parent) }
    }

    /// Right arrow: opens the selected folder; on an open one it selects its first row.
    public func expandOrSelectFirstChild() {
        let (row, index, searching) = lock.withLock { () -> (Row?, Int?, Bool) in
            let index = selectedIndex
            return (index.map { state.rows[$0] }, index, !state.query.isEmpty)
        }
        guard let row, let index, row.item.isDirectory else { return }
        if !row.isExpanded, !searching { expand(row.key); return }
        let hasChild = lock.withLock { state.rows.indices.contains(index + 1) && state.rows[index + 1].depth > row.depth }
        if hasChild { select(rowAt: index + 1) }
    }

    /// Return: opens or closes the selected folder. On a file it does what a click and then a double click do: picks it,
    /// then loads it (either may be unset).
    public func activateSelected(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let (row, index, pick, load) = lock.withLock { () -> (Row?, Int?, (@Sendable (WorkspaceEntry) -> Void)?, (@Sendable (WorkspaceEntry) -> Void)?) in
            let index = selectedIndex
            return (index.map { state.rows[$0] }, index, self.pick, self.load)
        }
        guard let row, let index else { return }
        if row.item.isDirectory { activate(row: index, now: now) } else { pick?(row.item.entry); load?(row.item.entry) }
    }

    public func expand(_ key: NodeKey) {
        let needsLoad = lock.withLock { () -> Bool in
            expanded.insert(key)
            persistExpandedLocked()
            guard children[key] == nil, !loading.contains(key) else { return false }
            loading.insert(key)
            return true
        }
        rebuild()
        guard needsLoad else { return }
        Task {
            await self.loadChildren(of: key)
            self.rebuild()
        }
    }

    public func collapse(_ key: NodeKey) {
        lock.withLock {
            _ = expanded.remove(key)
            persistExpandedLocked()
        }
        rebuild()
    }

    /// Saves the open folders when this tree has a persistence key. Called with `lock` held.
    private func persistExpandedLocked() {
        guard let expansionPersistenceKey else { return }
        let data = try? JSONEncoder().encode(expanded.sorted {
            if $0.folderID != $1.folderID { return $0.folderID.uuidString < $1.folderID.uuidString }
            return $0.path < $1.path
        })
        UserDefaults.standard.set(data, forKey: expansionPersistenceKey)
    }

    /// Whether `entry` may be dropped on the folder `destination`: not on itself, its parent (no change) or a descendant.
    func accepts(_ entry: WorkspaceEntry, on destination: NodeKey) -> Bool {
        guard lock.withLock({ drop != nil || moves }), entry.folderID == destination.folderID, !entry.path.isEmpty else { return false }
        let from = entry.path, to = destination.path
        if from == to || to.hasPrefix(from + "/") { return false }
        let parent = from.split(separator: "/").dropLast().joined(separator: "/")
        return parent != to
    }

    func drop(_ entry: WorkspaceEntry, on destination: NodeKey) -> Bool {
        let (custom, moves) = lock.withLock { (drop, self.moves) }
        if let custom {
            guard custom(entry, destination) else { return false }
            Task { await self.reload() }
            return true
        }
        guard moves else { return false }
        Task {
            do {
                try await self.workspace.move(folderID: entry.folderID, path: entry.path, toDirectory: destination.path)
                self.expand(destination)
            } catch {
                self.onError?(Self.describe(error))
            }
            await self.reload()
        }
        return true
    }

    private static func describe(_ error: Error) -> String {
        switch error as? WorkspaceError {
        case .alreadyExists?: "Something with that name is already there"
        case .readOnly?: "That folder is read-only"
        case .invalidPath?: "A folder cannot move into itself"
        default: (error as NSError).localizedDescription
        }
    }

    func setDropTarget(_ key: NodeKey, _ on: Bool) {
        lock.withLock {
            if on { state.dropTarget = key } else if state.dropTarget == key { state.dropTarget = nil }
        }
        invalidate()
    }

    public func setFilter(_ filter: BrowserFilter) {
        lock.withLock { self.filter = filter; children = [:] }
        Task { await self.reload() }
    }

    // MARK: - Search

    /// The text the names are filtered by.
    public var queryText: String { lock.withLock { state.query } }

    /// Shows only the names that contain `text` (any case) and the folders they sit in. Folders never opened are listed
    /// in the background (up to a limit) so a match below them is found.
    public func setQuery(_ text: String) {
        lock.withLock { state.query = text }
        rebuild()
        guard !text.isEmpty else { return }
        Task {
            await self.listFoldersForSearch(of: text)
            self.rebuild()
        }
    }

    private func listFoldersForSearch(of text: String) async {
        var listed = 0
        var tried: Set<NodeKey> = []
        while listed < Self.searchFolderLimit {
            let next = lock.withLock { () -> NodeKey? in
                guard state.query == text else { return nil }
                var queue = roots.map(Self.key)
                var index = 0
                while index < queue.count {
                    let key = queue[index]; index += 1
                    guard let kids = children[key] else {
                        if !loading.contains(key), !tried.contains(key) { return key }
                        continue            // being listed, or it could not be listed
                    }
                    queue.append(contentsOf: kids.filter(\.isDirectory).map(Self.key))
                }
                return nil
            }
            guard let next else { return }
            tried.insert(next)
            await loadChildren(of: next)
            listed += 1
            rebuild()
        }
    }

    // MARK: - Watching

    /// Lists the tree again whenever a registered folder is added or removed, or a listed folder's modification stamp moves.
    /// One `stat` per listed folder per tick while idle.
    public func startWatching(interval: TimeInterval = 1) {
        lock.withLock {
            watcher?.cancel()
            watcher = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(max(0.05, interval) * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    await self.refreshIfChanged()
                }
            }
        }
    }

    public func stopWatching() { lock.withLock { watcher?.cancel(); watcher = nil } }

    public func refreshIfChanged() async {
        let folders = await workspace.folders().filter { only == nil || $0.id == only }
        let (known, stamps) = lock.withLock { (knownFolders, self.stamps) }
        var changed = folders != known
        if !changed {
            for (key, old) in stamps {
                if let now = try? await workspace.directoryStamp(folderID: key.folderID, path: key.path), now != old { changed = true; break }
            }
        }
        if changed { await reload() }
    }

    // MARK: - Flattening

    private static func key(_ item: BrowserItem) -> NodeKey { NodeKey(folderID: item.entry.folderID, path: item.entry.path) }

    private func rebuild() {
        lock.withLock {
            let searching = !state.query.isEmpty
            var rows: [Row] = []
            // Depth-first with an explicit stack: a deep tree cannot overflow the call stack.
            var stack: [(BrowserItem, Int)] = roots.reversed().map { ($0, 0) }
            while let (item, depth) = stack.popLast() {
                let key = Self.key(item)
                // A search shows every folder it has listed, open or not.
                let isOpen = item.isDirectory && (searching ? children[key] != nil : expanded.contains(key))
                rows.append(Row(item: item, depth: depth, isExpanded: isOpen, isLoading: isOpen && !searching && loading.contains(key)))
                if isOpen, let kids = children[key] {
                    for kid in kids.reversed() { stack.append((kid, depth + 1)) }
                }
            }
            if searching { rows = Self.matching(rows, query: state.query) }
            state.rows = rows
            state.generation &+= 1
        }
        invalidate()
    }

    /// The rows whose name contains `query`, and the folders above them.
    static func matching(_ rows: [Row], query: String) -> [Row] {
        let needle = query.lowercased()
        var keep = [Bool](repeating: false, count: rows.count)
        // `want[d]`: the nearest row above, at depth `d`, holds a match and must stay.
        var want = [Bool](repeating: false, count: (rows.map(\.depth).max() ?? 0) + 1)
        for index in rows.indices.reversed() {
            let depth = rows[index].depth
            if want[depth] || rows[index].item.name.lowercased().contains(needle) {
                keep[index] = true
                for above in 0..<depth { want[above] = true }
            }
            want[depth] = false
        }
        return rows.indices.filter { keep[$0] }.map { rows[$0] }
    }
}
