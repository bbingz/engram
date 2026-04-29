import GRDB
import EngramCoreRead

public final class SessionBatchUpsert: IndexingWriteSink {
    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    public func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        let writer = SessionSnapshotWriter(db: db)
        var results: [SessionBatchItemResult] = []
        for snapshot in snapshots {
            do {
                let writeResult = try writer.writeAuthoritativeSnapshot(snapshot)
                results.append(
                    SessionBatchItemResult(
                        sessionId: snapshot.id,
                        action: writeResult.action,
                        enqueuedJobs: writer.jobKinds(for: writeResult, snapshot: snapshot)
                    )
                )
            } catch {
                results.append(
                    SessionBatchItemResult(
                        sessionId: snapshot.id,
                        action: .failure,
                        enqueuedJobs: [],
                        error: "\(error)"
                    )
                )
            }
        }
        return SessionBatchUpsertResult(reason: reason, results: results)
    }
}
