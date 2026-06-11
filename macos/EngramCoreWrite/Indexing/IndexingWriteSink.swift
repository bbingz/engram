import EngramCoreRead

public struct KnownIndexedFileState: Equatable, Sendable {
    public let sizeBytes: Int64
    public let indexedAt: String?

    public init(sizeBytes: Int64, indexedAt: String?) {
        self.sizeBytes = sizeBytes
        self.indexedAt = indexedAt
    }
}

// Not refined to `Sendable`: a conforming type (`SessionBatchUpsert`) wraps a
// connection-bound GRDB `Database` that must stay on its owning thread, so the
// protocol cannot promise cross-thread safety for all conformers.
public protocol IndexingWriteSink {
    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult

    func knownIndexedFileStates(source: SourceName, locators: [String]) throws -> [String: KnownIndexedFileState]
}

public extension IndexingWriteSink {
    func knownIndexedFileStates(source: SourceName, locators: [String]) throws -> [String: KnownIndexedFileState] {
        [:]
    }
}
