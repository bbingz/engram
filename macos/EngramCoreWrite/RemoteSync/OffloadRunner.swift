import Foundation

/// Drives one offload/rehydrate cycle against a writer + backend. Each DB step is
/// its own `writer.write`; the network PUT/GET happens BETWEEN write transactions,
/// never inside one. The service runs the same sequence with each write wrapped in
/// `ServiceWriterGate.performWriteCommand` (so the gate is released across the
/// network call); this struct is the gate-free vehicle used by unit tests and any
/// standalone caller.
public struct OffloadRunner: Sendable {
    private let writer: EngramDatabaseWriter
    private let backend: any RemoteStorageBackend
    private let policy: OffloadPolicy
    private let peer: String?

    public init(
        writer: EngramDatabaseWriter,
        backend: any RemoteStorageBackend,
        policy: OffloadPolicy = OffloadPolicy(),
        peer: String? = nil
    ) {
        self.writer = writer
        self.backend = backend
        self.policy = policy
        self.peer = peer
    }

    public struct SyncOutcome: Sendable, Equatable {
        public let succeeded: Int
        public let failed: Int

        public init(succeeded: Int, failed: Int) {
            self.succeeded = succeeded
            self.failed = failed
        }
    }

    /// Enqueue policy-eligible sessions, then drain one batch of pending offloads.
    @discardableResult
    public func runOffloadOnce(
        now: Date = Date(),
        candidateLimit: Int = 500,
        batchLimit: Int = 50
    ) async throws -> SyncOutcome {
        // Reclaim inflight jobs orphaned by a crashed/cancelled prior cycle.
        _ = try writer.write { db in try OffloadRepo.requeueStaleInflight(db) }
        try writer.write { db in
            let eligible = try OffloadRepo.candidateRows(db, limit: candidateLimit)
                .filter { policy.isEligible($0, now: now) }
                .sorted { policy.score($0, now: now) > policy.score($1, now: now) }
                .map(\.id)
            try OffloadRepo.enqueueOffload(db, sessionIds: eligible, generation: nil)
        }

        let claimed = try writer.write { db in try OffloadRepo.claimPendingOffload(db, limit: batchLimit) }
        var succeeded = 0
        var failed = 0
        for job in claimed {
            do {
                guard let inputs = try writer.read({ db in
                    try OffloadRepo.bundleInputs(db, sessionId: job.sessionId)
                }) else {
                    try writer.write { db in
                        try OffloadRepo.failOffload(db, queueId: job.queueId, error: "session row missing")
                    }
                    failed += 1
                    continue
                }

                let bundle = BundleCodec.makeBundle(
                    sessionId: job.sessionId,
                    ftsContents: inputs.ftsContents,
                    summary: inputs.summary,
                    summaryMessageCount: inputs.summaryMessageCount,
                    messageCount: inputs.messageCount,
                    userMessageCount: inputs.userMessageCount,
                    assistantMessageCount: inputs.assistantMessageCount,
                    toolMessageCount: inputs.toolMessageCount,
                    systemMessageCount: inputs.systemMessageCount
                )
                let key = BundleCodec.contentKey(bundle)

                // Network — strictly outside any write transaction. HEAD is only
                // an optimization: an existing object is fetched and verified;
                // an absent object is proven by a successful idempotent PUT.
                try await backend.ensureDurable(bundle: bundle)

                let shadow = OffloadShadow.line(
                    title: inputs.generatedTitle,
                    project: inputs.project,
                    summary: inputs.summary,
                    sessionId: job.sessionId
                )
                try writer.write { db in
                    try OffloadRepo.commitOffloaded(
                        db,
                        queueId: job.queueId,
                        sessionId: job.sessionId,
                        expectedSyncVersion: inputs.syncVersion,
                        remoteKey: key,
                        contentHash: bundle.contentHash,
                        shadowLine: shadow,
                        peer: peer
                    )
                }
                succeeded += 1
            } catch let error as CancellationError {
                throw error
            } catch RemoteSyncError.offloadStale {
                // Re-indexed/removed mid-flight: re-queue and re-capture next cycle
                // (NOT a failure — no attempts charged, no purge happened).
                try writer.write { db in try OffloadRepo.requeueOffload(db, queueId: job.queueId) }
            } catch {
                try writer.write { db in
                    try OffloadRepo.failOffload(db, queueId: job.queueId, error: "\(error)")
                }
                failed += 1
            }
        }
        return SyncOutcome(succeeded: succeeded, failed: failed)
    }

    /// Drain one batch of pending rehydrates: fetch the bundle, verify, restore.
    @discardableResult
    public func runRehydrateOnce(batchLimit: Int = 50) async throws -> SyncOutcome {
        _ = try writer.write { db in try OffloadRepo.requeueStaleInflight(db) }
        let claimed = try writer.write { db in try OffloadRepo.claimPendingRehydrate(db, limit: batchLimit) }
        var succeeded = 0
        var failed = 0
        for job in claimed {
            do {
                guard let key = try writer.read({ db in
                    try OffloadRepo.latestRemoteKey(db, sessionId: job.sessionId)
                }) else {
                    try writer.write { db in
                        try OffloadRepo.failRehydrate(db, queueId: job.queueId, error: "no remote key in ledger")
                    }
                    failed += 1
                    continue
                }
                let data = try await backend.get(key: key)
                let bundle = try BundleCodec.decode(data, expectedSessionId: job.sessionId)
                try writer.write { db in
                    try OffloadRepo.commitRehydrated(
                        db,
                        queueId: job.queueId,
                        bundle: bundle,
                        expectedSyncVersion: job.syncVersion ?? 0,
                        peer: peer
                    )
                }
                succeeded += 1
            } catch RemoteSyncError.offloadStale {
                try writer.write { db in try OffloadRepo.requeueRehydrate(db, queueId: job.queueId) }
            } catch let error as CancellationError {
                throw error
            } catch {
                try writer.write { db in
                    try OffloadRepo.failRehydrate(db, queueId: job.queueId, error: "\(error)")
                }
                failed += 1
            }
        }
        return SyncOutcome(succeeded: succeeded, failed: failed)
    }
}
