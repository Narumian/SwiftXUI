import Foundation
import XWorkspace
import XUI

/// Everything a browser shows and does, independent of how it is drawn.
///
/// Listing, ordering and filtering happen off the UI actor; a frame only copies
/// the current `Snapshot` (array references, no per-item work).
public final class FileBrowserModel: @unchecked Sendable {
    public enum Location: Hashable, Sendable {
        /// The registered folders themselves.
        case roots
        case folder(id: UUID, path: String)
    }

    public struct Snapshot: Sendable {
        public var location: Location = .roots
        public var title = ""
        public var folders: [WorkspaceFolder] = []
        /// Sorted; `visible` indexes into it.
        public var items: [BrowserItem] = []
        public var visible: [Int32] = []
        public var selectedPath: String?
        public var isLoading = false
        public var error: String?
        /// Bumps whenever `items` or `visible` change.
        public var generation = 0
        public var isReadOnly = false
        /// True when the browser is choosing folders rather than files.
        public var choosesFolders = false

        public var canGoUp: Bool { location != .roots }
        /// Changes when the grid should return to its start.
        public var resetKey: String {
            switch location {
            case .roots: "roots"
            case .folder(let id, let path): id.uuidString + "/" + path
            }
        }
        public func item(atVisible index: Int) -> BrowserItem? {
            guard visible.indices.contains(index) else { return nil }
            return items[Int(visible[index])]
        }
    }

    private let workspace: Workspace
    private let invalidate: @Sendable () -> Void
    private let lock = NSLock()
    private var state = Snapshot()
    private var filter: BrowserFilter
    private var query = ""
    private var stamp: Date?
    private var loadToken = 0
    private var shape: BrowserLayout.Shape?
    private var watcher: Task<Void, Never>?
    /// Called when a file (not a folder) is chosen.
    public var onPick: (@Sendable (WorkspaceEntry) -> Void)? {
        get { lock.withLock { pick } }
        set { lock.withLock { pick = newValue } }
    }
    private var pick: (@Sendable (WorkspaceEntry) -> Void)?
    /// When set, the browser offers a button that chooses the folder being viewed.
    public var onChooseFolder: (@Sendable (_ folderID: UUID, _ path: String) -> Void)? {
        get { lock.withLock { choose } }
        set { lock.withLock { choose = newValue }; invalidate() }
    }
    private var choose: (@Sendable (UUID, String) -> Void)?

    /// Chooses the folder currently shown, if the browser is in folder-choosing mode.
    public func chooseCurrentFolder() {
        let (location, choose) = lock.withLock { (state.location, self.choose) }
        if case .folder(let id, let path) = location { choose?(id, path) }
    }

    public init(workspace: Workspace, filter: BrowserFilter = .all, invalidate: @escaping @Sendable () -> Void = {}) {
        self.workspace = workspace
        self.filter = filter
        self.invalidate = invalidate
    }

    deinit { watcher?.cancel() }

    public func snapshot() -> Snapshot {
        lock.withLock { var copy = state; copy.choosesFolders = choose != nil; return copy }
    }

    /// The layout shape last used, so a box resized across a boundary keeps its shape until it clearly leaves it.
    public func resolveLayout(_ policy: BrowserLayoutPolicy, size: Size) -> BrowserLayout {
        lock.withLock {
            let layout = policy.layout(for: size, previous: shape)
            shape = layout.shape
            return layout
        }
    }

    // MARK: - Navigation

    public func open(_ location: Location) {
        let token = lock.withLock { () -> Int in
            loadToken += 1
            state.location = location
            state.isLoading = true
            state.error = nil
            state.selectedPath = nil
            stamp = nil
            return loadToken
        }
        invalidate()
        Task { await self.load(location, token: token) }
    }

    public func goUp() {
        let current = lock.withLock { state.location }
        switch current {
        case .roots: break
        case .folder(let id, let path):
            if path.isEmpty { open(.roots) }
            else { open(.folder(id: id, path: path.split(separator: "/").dropLast().joined(separator: "/"))) }
        }
    }

    /// Opens a folder, or picks a file.
    public func activate(visibleIndex: Int) {
        let (item, pick) = lock.withLock { (state.item(atVisible: visibleIndex), self.pick) }
        guard let item else { return }
        if item.isDirectory {
            open(.folder(id: item.entry.folderID, path: item.entry.path))
        } else {
            lock.withLock { state.selectedPath = item.entry.path }
            invalidate()
            pick?(item.entry)
        }
    }

    public func setQuery(_ text: String) {
        lock.withLock { query = text; refilter() }
        invalidate()
    }

    public func setFilter(_ filter: BrowserFilter) {
        lock.withLock { self.filter = filter; refilter() }
        invalidate()
    }

    /// Lists the current location again.
    public func reload() async {
        let (location, token) = lock.withLock { () -> (Location, Int) in
            loadToken += 1
            return (state.location, loadToken)
        }
        await load(location, token: token)
    }

    /// Shows a listing that did not come from a workspace folder (search results,
    /// a generated set). Sorted and filtered like any other.
    public func showItems(_ items: [BrowserItem], title: String = "") {
        let sorted = BrowserOrdering.sorted(items)
        lock.withLock {
            loadToken += 1
            state.location = .roots
            state.items = sorted
            state.title = title
            state.isLoading = false
            state.error = nil
            state.selectedPath = nil
            refilter()
        }
        invalidate()
    }

    // MARK: - Watching

    /// Re-lists the current folder whenever its modification stamp moves. One `stat` per tick while idle.
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
        let (location, known) = lock.withLock { (state.location, stamp) }
        switch location {
        case .roots:
            let folders = await workspace.folders()
            let changed = lock.withLock { folders != state.folders }
            if changed { await reload() }
        case .folder(let id, let path):
            let now = try? await workspace.directoryStamp(folderID: id, path: path)
            if now != known { await reload() }
        }
    }

    // MARK: - Loading

    private func load(_ location: Location, token: Int) async {
        let folders = await workspace.folders()
        var items: [BrowserItem] = []
        var newStamp: Date?
        var failure: String?
        var readOnly = false
        switch location {
        case .roots:
            items = folders.map { BrowserItem(entry: WorkspaceEntry(folderID: $0.id, path: "", kind: .directory), displayName: $0.name) }
        case .folder(let id, let path):
            readOnly = folders.first { $0.id == id }?.isReadOnly ?? false
            do {
                newStamp = try await workspace.directoryStamp(folderID: id, path: path)
                let entries = try await workspace.list(folderID: id, path: path, sorted: false)
                items = entries.map { BrowserItem(entry: $0) }
            } catch {
                failure = Self.describe(error)
            }
        }
        // Ordering is the expensive step for big folders; keep it off any UI actor.
        let sorted = await Task.detached(priority: .userInitiated) { BrowserOrdering.sorted(items) }.value
        let applied = lock.withLock { () -> Bool in
            guard token == loadToken else { return false }
            state.folders = folders
            state.items = sorted
            state.isLoading = false
            state.error = failure
            state.isReadOnly = readOnly
            state.title = Self.title(location, folders: folders)
            stamp = newStamp
            refilter()
            return true
        }
        if applied { invalidate() }
    }

    /// Caller holds the lock.
    private func refilter() {
        state.visible = BrowserOrdering.visible(in: state.items, filter: filter, query: query)
        state.generation &+= 1
    }

    private static func title(_ location: Location, folders: [WorkspaceFolder]) -> String {
        switch location {
        case .roots: return "FOLDERS"
        case .folder(let id, let path):
            if let last = path.split(separator: "/").last { return String(last) }
            return folders.first { $0.id == id }?.name ?? ""
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? WorkspaceError {
        case .folderNotFound?: "Folder not found"
        case .invalidFolder?: "Folder unavailable — reconnect it"
        case .invalidPath?: "Invalid path"
        default: (error as NSError).localizedDescription
        }
    }
}
