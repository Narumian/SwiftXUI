import Foundation

/// Host services for the project location and small restoration preferences.
/// Access leases must stay alive until the project is replaced.
@MainActor
public protocol DocumentProjectEnvironment: AnyObject {
    func defaultFolder() throws -> URL
    func restoredFolder() throws -> URL?
    func acquire(folder: URL) throws -> any DocumentFolderAccess
    func remember(folder: URL) throws
    var restoredPage: String { get set }
}

@MainActor
public protocol DocumentFolderAccess: AnyObject {
    func releaseAccess()
}

public struct DocumentProjectState<Document: Sendable>: Sendable {
    public var folder: URL?
    public var document: Document?
    public var page: String
    public var revision: UUID
    public var error: String?
}

/// Platform-independent controller for one project, restoration and autosave.
/// A host supplies only location/permission services and presents state changes.
@MainActor
public final class DocumentProjectController<Document: Codable & Sendable> {
    public private(set) var state: DocumentProjectState<Document> {
        didSet { onChange?(state) }
    }
    public var onChange: (@MainActor (DocumentProjectState<Document>) -> Void)?
    private let environment: any DocumentProjectEnvironment
    private let filename: String
    private let initial: @Sendable () -> Document
    private let initialDefault: @Sendable () -> Document
    private let validate: @Sendable (Document) throws -> Void
    private var session: DocumentSession<Document, LocalDocumentStorage>?
    private var access: (any DocumentFolderAccess)?
    private var pending: Task<Void, Never>?
    private var isSwitching = false
    private var saveFailed = false

    public init(environment: any DocumentProjectEnvironment, filename: String,
                initial: @escaping @Sendable () -> Document,
                initialDefault: (@Sendable () -> Document)? = nil,
                validate: @escaping @Sendable (Document) throws -> Void = { _ in }) {
        self.environment = environment
        self.filename = filename
        self.initial = initial
        self.initialDefault = initialDefault ?? initial
        self.validate = validate
        self.state = DocumentProjectState(folder: nil, document: nil, page: "", revision: UUID(), error: nil)
    }

    public func start() async {
        guard session == nil, !isSwitching else { return }
        do {
            let page = environment.restoredPage
            let restored = try environment.restoredFolder()
            let folder = try restored ?? environment.defaultFolder()
            try await open(folder: folder, page: page, useDefaultInitial: restored == nil)
        } catch { state.error = error.localizedDescription }
    }

    public func open(folder: URL, page: String = "") async throws {
        try await open(folder: folder, page: page, useDefaultInitial: false)
    }

    private func open(folder: URL, page: String, useDefaultInitial: Bool) async throws {
        guard !isSwitching else { throw ControllerError.switchInProgress }
        isSwitching = true
        defer { isSwitching = false }
        await pending?.value
        if saveFailed, let session, let value = state.document {
            try await session.edit("Retry Save") { $0 = value }
            try await session.save()
            saveFailed = false
        }
        if let session, await session.status().isDirty { try await session.save() }
        let lease = try environment.acquire(folder: folder)
        do {
            let url = folder.appendingPathComponent(filename, isDirectory: false)
            let next: DocumentSession<Document, LocalDocumentStorage>
            if FileManager.default.fileExists(atPath: url.path) {
                next = try .open(at: url, storage: .init())
                try validate(await next.document())
            } else {
                next = try .create(useDefaultInitial ? initialDefault() : initial(), at: url, storage: .init())
                try await next.save()
            }
            let document = try await next.document()
            try environment.remember(folder: folder)
            access?.releaseAccess()
            access = lease
            session = next
            environment.restoredPage = page
            state = DocumentProjectState(folder: folder, document: document, page: page, revision: UUID(), error: nil)
        } catch {
            lease.releaseAccess()
            throw error
        }
    }

    /// Schedules edits in order. Callers see the new value after it is applied;
    /// errors are reported in state and unsaved edits remain available to retry.
    public func edit(_ name: String, _ change: @escaping @Sendable (inout Document) throws -> Void) {
        guard let session, !isSwitching, var value = state.document else { return }
        do { try change(&value) }
        catch { state.error = error.localizedDescription; return }
        state.document = value
        let snapshot = value
        let previous = pending
        pending = Task {
            await previous?.value
            do {
                try await session.edit(name) { $0 = snapshot }
                try await session.save()
                saveFailed = false
            } catch { saveFailed = true; state.error = error.localizedDescription }
        }
    }

    public func navigate(to page: String) {
        guard state.page != page else { return }
        environment.restoredPage = page
        state.page = page
        state.revision = UUID()
    }

    public func clearError() { state.error = nil }
    public func reportError(_ error: Error) { state.error = error.localizedDescription }

    public enum ControllerError: Error { case switchInProgress }
}
