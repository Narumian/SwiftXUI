# XDocument

`DocumentSession` owns a single document, its save point, and its undo/redo
history. It is independent of XUI, file browsers, platform permissions, and MCP.
A host opens or creates a session using a `DocumentStorage` adapter. The model
must be `Codable` and encode all persistent state. `DocumentCodec` controls the
file format; internal history uses JSON snapshots independently of that codec.

Use `edit` for a discrete change. For live gestures, use `beginEditGroup`,
`updateEditGroup`, and `endEditGroup` (or `cancelEditGroup`). Intermediate
values can be read, but saving and undo/redo are blocked until the group ends.
A throwing edit does not commit its partial changes. Editing after undo discards
redo history. Dirty state tracks the saved history position, including branches.
A new document is dirty until first saved. Closing a dirty document requires an
explicit discard. A save failure leaves the session and its save point intact.

Storage implementations own access permissions, coordination and conflict
checking: a write must reject changes since the data passed in `replacing` was
read; `nil` means the destination must not exist. `LocalDocumentStorage` offers
best-effort conflict detection and atomic replacement for ordinary local files,
but its check and replacement are not a cross-process atomic operation. Use a
platform-coordinated adapter for stronger guarantees and document providers.
Storage calls are synchronous on the session actor. This first implementation
keeps full snapshots for every undo step and does not bound history; it is suited
to small documents, not large assets. Persist access tokens and restore locations
in the host; neither is serialized into the document or history.
