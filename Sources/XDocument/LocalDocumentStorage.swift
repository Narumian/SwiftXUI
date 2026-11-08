import Foundation

/// Local-file storage for processes which already have access to the file.
/// Access grants and coordination with document providers belong to an adapter.
/// The conflict check and atomic replacement are not a cross-process compare-
/// and-swap; hosts requiring that guarantee must provide coordinated storage.
public struct LocalDocumentStorage: DocumentStorage {
    public init() {}

    public func read(from location: URL) throws -> Data {
        try Data(contentsOf: location)
    }

    public func write(_ data: Data, to location: URL, replacing expected: Data?) throws {
        let existing: Data?
        do {
            existing = try Data(contentsOf: location)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            existing = nil
        }
        guard existing == expected else { throw DocumentSessionError.externalModification }
        try data.write(to: location, options: .atomic)
    }
}
