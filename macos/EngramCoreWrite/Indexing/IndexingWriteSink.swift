import EngramCoreRead

// Not refined to `Sendable`: a conforming type (`SessionBatchUpsert`) wraps a
// connection-bound GRDB `Database` that must stay on its owning thread, so the
// protocol cannot promise cross-thread safety for all conformers.
public protocol IndexingWriteSink {
    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult
}
