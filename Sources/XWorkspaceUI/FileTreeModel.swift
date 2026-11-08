import Foundation
import XWorkspace

/// The state behind an outline of folders and files, like a project navigator.
///
/// Folders load the first time they open and stay cached; the tree is flattened into
/// rows once per change, so a frame only reads `Snapshot.rows`.
public final class FileTreeModel: @unchecked Sendable {
    /// A folder or file, identified across folders.
    public struct NodeKey: Hashable, Sendable {
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
        public var error: String?
        /// Bumps whenever `rows` change.
        public var generation = 0
    }

    private let workspace: Workspace
    private let only: UUID?
    private let invalidate: @Sendable () -> Void
    private let lock = NSLock()

    private var filter: BrowserFilter
    private var roots: [BrowserItem] = []
    private var children: [NodeKey: [BrowserItem]] = [:]
    private var expanded: Set<NodeKey> = []
    private var loading: Set<NodeKey> = []
    private var state = Snapshot()
    private var pick: (@Sendable (WorkspaceEntry) -> Void)?

    /// - Parameter folderID: show just this registered folder as the root; nil shows every registered folder.
    public init(workspace: Workspace, folderID: UUID? = nil, filter: BrowserFilter = .all,
                invalidate: @escaping @Sendable () -> Void = {}) {
        self.workspace = workspace
        self.only = folderID
        self.filter = filter
        self.invalidate = invalidate
    }

    /// Called when a file (not a folder) is chosen.
    public var onPick: (@Sendable (WorkspaceEntry) -> Void)? {
        get { lock.withLock { pick } }
        set { lock.withLock { pick = newValue } }
    }

    public func snapshot() -> Snapshot { lock.withLock { state } }

    // MARK: - Loading

    /// Lists the roots again, and every open folder under them.
    public func reload() async {
        let folders = await workspace.folders().filter { only == nil || $0.id == only }
        let items = folders.map { BrowserItem(entry: WorkspaceEntry(folderID: $0.id, path: "", kind: .directory), displayName: $0.name) }
        let open = lock.withLock { expanded }
        lock.withLock {
            roots = items
            // A lone root opens by itself, as a project does.
            if only != nil, let root = items.first, state.rows.isEmpty { expanded.insert(Self.key(root)) }
        }
        let wanted = lock.withLock { expanded.union(open) }
        for key in wanted.sorted(by: { $0.path.count < $1.path.count }) { await loadChildren(of: key) }
        rebuild()
    }

    private func loadChildren(of key: NodeKey) async {
        lock.withLock { _ = loading.insert(key) }
        var listed: [BrowserItem]?
        var failure: String?
        do {
            let entries = try await workspace.list(folderID: key.folderID, path: key.path, sorted: false)
            let filter = lock.withLock { self.filter }
            let items = entries.map { BrowserItem(entry: $0) }.filter { filter.admits($0) }
            listed = await Task.detached(priority: .userInitiated) { BrowserOrdering.sorted(items) }.value
        } catch {
            failure = (error as NSError).localizedDescription
        }
        lock.withLock {
            loading.remove(key)
            if let listed { children[key] = listed; state.error = nil }
            else { expanded.remove(key); state.error = failure }
        }
    }

    // MARK: - Interaction

    /// Opens or closes a folder row; selects and picks a file row.
    public func activate(row index: Int) {
        let (row, pick) = lock.withLock { (state.rows.indices.contains(index) ? state.rows[index] : nil, self.pick) }
        guard let row else { return }
        if row.item.isDirectory {
            lock.withLock { state.selected = row.key }
            row.isExpanded ? collapse(row.key) : expand(row.key)
        } else {
            lock.withLock { state.selected = row.key }
            rebuild()
            pick?(row.item.entry)
        }
    }

    public func expand(_ key: NodeKey) {
        let needsLoad = lock.withLock { () -> Bool in
            expanded.insert(key)
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
        lock.withLock { _ = expanded.remove(key) }
        rebuild()
    }

    public func setFilter(_ filter: BrowserFilter) {
        lock.withLock { self.filter = filter; children = [:] }
        Task { await self.reload() }
    }

    // MARK: - Flattening

    private static func key(_ item: BrowserItem) -> NodeKey { NodeKey(folderID: item.entry.folderID, path: item.entry.path) }

    private func rebuild() {
        lock.withLock {
            var rows: [Row] = []
            // Depth-first with an explicit stack: a deep tree cannot overflow the call stack.
            var stack: [(BrowserItem, Int)] = roots.reversed().map { ($0, 0) }
            while let (item, depth) = stack.popLast() {
                let key = Self.key(item)
                let isOpen = item.isDirectory && expanded.contains(key)
                rows.append(Row(item: item, depth: depth, isExpanded: isOpen, isLoading: isOpen && loading.contains(key)))
                if isOpen, let kids = children[key] {
                    for kid in kids.reversed() { stack.append((kid, depth + 1)) }
                }
            }
            state.rows = rows
            state.generation &+= 1
        }
        invalidate()
    }
}
