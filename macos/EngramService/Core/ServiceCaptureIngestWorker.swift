import Foundation
import GRDB
import EngramCoreRead
import EngramCoreWrite

public enum ServiceCaptureIngestWorkerError: Error, Equatable {
    case notImplemented
}

public struct ServiceCaptureIngestParserPolicy: Equatable, Sendable {
    public var parserRevision: String
    public var enabledSources: Set<SourceName>

    public init(parserRevision: String, enabledSources: Set<SourceName>) {
        self.parserRevision = parserRevision
        self.enabledSources = enabledSources
    }
}

public enum ServiceCaptureIngestStepResult: Equatable, Sendable {
    case idle
    case busy
    case parsed(CaptureIngestCommittedGeneration)
    case recordedFailure
}

public struct ServiceCaptureIngestWorkerHooks: Sendable {
    public var queuedAtGate: (@Sendable () async throws -> Void)?
    public var beforeWriterTransaction: (@Sendable () throws -> Void)?
    public var afterClaim: (@Sendable () async throws -> Void)?
    public var beforeReplay: (@Sendable () async throws -> Void)?
    public var afterReplay: (@Sendable () async throws -> Void)?
    public var afterParsedMaterialization: (@Sendable () throws -> Void)?
    public var afterFailureMaterialization: (@Sendable () throws -> Void)?

    public init(
        queuedAtGate: (@Sendable () async throws -> Void)? = nil,
        beforeWriterTransaction: (@Sendable () throws -> Void)? = nil,
        afterClaim: (@Sendable () async throws -> Void)? = nil,
        beforeReplay: (@Sendable () async throws -> Void)? = nil,
        afterReplay: (@Sendable () async throws -> Void)? = nil,
        afterParsedMaterialization: (@Sendable () throws -> Void)? = nil,
        afterFailureMaterialization: (@Sendable () throws -> Void)? = nil
    ) {
        self.queuedAtGate = queuedAtGate
        self.beforeWriterTransaction = beforeWriterTransaction
        self.afterClaim = afterClaim
        self.beforeReplay = beforeReplay
        self.afterReplay = afterReplay
        self.afterParsedMaterialization = afterParsedMaterialization
        self.afterFailureMaterialization = afterFailureMaterialization
    }
}

/// Cold Service worker: claim → public CAS replay → parsed commit. No scheduler.
public actor ServiceCaptureIngestWorker {
    public static let claimCommandName = "captureIngestClaim"
    public static let commitCommandName = "captureIngestCommit"
    public static let failureCommandName = "captureIngestFailure"

    private let gate: ServiceWriterGate
    private let cas: ImmutableArchiveCAS
    private let stagingParent: URL
    private let policy: @Sendable () -> ServiceCaptureIngestParserPolicy?
    private let unixClock: @Sendable () -> Int64
    private let deadline: ContinuousClock.Instant?
    private let leaseDuration: Int64
    private let retryDelay: Int64
    private let hooks: ServiceCaptureIngestWorkerHooks
    private var owned: Task<ServiceCaptureIngestStepResult, Error>?
    private var sealed = false

    public init(
        gate: ServiceWriterGate,
        cas: ImmutableArchiveCAS,
        stagingParent: URL,
        policy: @escaping @Sendable () -> ServiceCaptureIngestParserPolicy?,
        unixClock: @escaping @Sendable () -> Int64,
        deadline: ContinuousClock.Instant? = nil,
        leaseDuration: Int64 = 300,
        retryDelay: Int64 = 30,
        hooks: ServiceCaptureIngestWorkerHooks = .init()
    ) {
        self.gate = gate
        self.cas = cas
        self.stagingParent = stagingParent
        self.policy = policy
        self.unixClock = unixClock
        self.deadline = deadline
        self.leaseDuration = leaseDuration
        self.retryDelay = retryDelay
        self.hooks = hooks
    }

    public func step() async throws -> ServiceCaptureIngestStepResult {
        try Task.checkCancellation()
        if sealed { return .idle }
        if owned != nil { return .busy }
        let work = CaptureIngestWork(
            gate: gate, cas: cas, stagingParent: stagingParent, policy: policy,
            unixClock: unixClock, deadline: deadline, leaseDuration: leaseDuration,
            retryDelay: retryDelay, hooks: hooks
        )
        let task = Task { try await work.run() }
        owned = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            owned = nil
            return result
        } catch {
            owned = nil
            throw error
        }
    }

    public func stop() async throws {
        sealed = true
        owned?.cancel()
        if let task = owned {
            _ = try? await task.value
        }
        owned = nil
    }
}

private struct NeutralOutcome: Error {}
private struct TransactionFence: Error {}

private struct CaptureIngestWork: Sendable {
    let gate: ServiceWriterGate
    let cas: ImmutableArchiveCAS
    let stagingParent: URL
    let policy: @Sendable () -> ServiceCaptureIngestParserPolicy?
    let unixClock: @Sendable () -> Int64
    let deadline: ContinuousClock.Instant?
    let leaseDuration: Int64
    let retryDelay: Int64
    let hooks: ServiceCaptureIngestWorkerHooks

    func run() async throws -> ServiceCaptureIngestStepResult {
        try await ServiceWriterGate.$preserveAcceptedWriteProducer.withValue(false) {
            try await execute()
        }
    }

    private func execute() async throws -> ServiceCaptureIngestStepResult {
        try checkFences()
        try validateDurations()
        try await hooks.queuedAtGate?()
        try checkFences()
        guard usablePolicy() != nil else { return .idle }
        let picked: (CaptureIngestClaim, CaptureIngestSourceBinding)
        do {
            guard let value = try await write(ServiceCaptureIngestWorker.claimCommandName, { writer in
                try self.hooks.beforeWriterTransaction?()
                try self.checkFences()
                return try self.withBorrowedTask { task in
                    try writer.write { db in
                        try self.requireBorrowed(task)
                        return try self.claim(db, task: task)
                    }
                }
            }) else { return .idle }
            picked = value
        } catch is NeutralOutcome {
            return .idle
        }
        try await hooks.afterClaim?()
        try checkFences()
        try await hooks.beforeReplay?()
        try checkFences()
        let replayOutcome: Result<CaptureIngestReplayResult, CaptureIngestReplayError>
        do {
            replayOutcome = .success(try await CaptureIngestReplay.replay(
                publication: picked.0.publication, bindingSnapshot: picked.1,
                cas: cas, stagingParent: stagingParent
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CaptureIngestReplayError {
            replayOutcome = .failure(error)
        }
        try await hooks.afterReplay?()
        try checkFences()
        let replay: CaptureIngestReplayResult
        switch replayOutcome {
        case .success(let value):
            replay = value
        case .failure(let error):
            return try await recordMappedFailure(claim: picked.0, binding: picked.1, error: error)
        }
        do {
            let receipt = try await write(ServiceCaptureIngestWorker.commitCommandName, { writer in
                try self.withBorrowedTask { task in
                    try writer.write { db in
                        try self.requireBorrowed(task)
                        try self.requireCurrentAuthority(db, claim: picked.0, binding: picked.1, committed: false)
                        let now = try self.requireLiveLease(picked.0, committed: false)
                        let receipt = try CaptureIngestCommitter.commitParsed(
                            db, claim: picked.0, replay: replay,
                            expectedParserRevision: picked.0.parserRevision,
                            now: now, indexedAt: self.indexedAt(from: now)
                        )
                        try self.hooks.afterParsedMaterialization?()
                        try self.requireBorrowed(task)
                        try self.requireCurrentAuthority(db, claim: picked.0, binding: picked.1, committed: true)
                        _ = try self.requireLiveLease(picked.0, committed: true)
                        try self.checkDeadline()
                        return receipt
                    }
                }
            })
            return .parsed(receipt)
        } catch is CancellationError {
            throw CancellationError()
        } catch is NeutralOutcome {
            return .idle
        } catch let error as CaptureIngestCommitError {
            switch error {
            case .parserRevisionChanged, .bindingChanged:
                return .idle
            default:
                throw error
            }
        } catch CaptureIngestLedgerError.claimLost {
            return .idle
        }
    }

    private func recordMappedFailure(
        claim: CaptureIngestClaim, binding: CaptureIngestSourceBinding, error: CaptureIngestReplayError
    ) async throws -> ServiceCaptureIngestStepResult {
        let failure = mapReplay(error)
        do {
            try await write(ServiceCaptureIngestWorker.failureCommandName, { writer in
                try self.withBorrowedTask { task in
                    try writer.write { db in
                        try self.requireBorrowed(task)
                        try self.requireCurrentAuthority(db, claim: claim, binding: binding, committed: false)
                        let now = try self.requireLiveLease(claim, committed: false)
                        let delay: Int64?
                        if case .retryable = failure { delay = self.retryDelay } else { delay = nil }
                        try CaptureIngestLedger.recordFailure(
                            db, claim: claim, failure: failure, now: now, retryDelay: delay
                        )
                        try self.hooks.afterFailureMaterialization?()
                        try self.requireBorrowed(task)
                        try self.requireCurrentAuthority(db, claim: claim, binding: binding, committed: true)
                        _ = try self.requireLiveLease(claim, committed: true)
                        try self.checkDeadline()
                    }
                }
            })
            return .recordedFailure
        } catch is CancellationError {
            throw CancellationError()
        } catch is NeutralOutcome {
            return .idle
        } catch CaptureIngestLedgerError.claimLost {
            return .idle
        }
    }

    private func claim(
        _ db: Database, task: UnsafeCurrentTask?
    ) throws -> (CaptureIngestClaim, CaptureIngestSourceBinding)? {
        guard let policy = usablePolicy() else { return nil }
        let now = unixClock()
        guard now >= 0 else { throw CaptureIngestLedgerError.invalidTime }
        guard let key = try preselect(db, policy: policy, now: now) else { return nil }
        guard let fresh = usablePolicy(),
              fresh.parserRevision.utf8.elementsEqual(key.revision.utf8),
              fresh.enabledSources == policy.enabledSources else { return nil }
        guard let claimed = try CaptureIngestLedger.claim(
            db, publicationSHA256: key.digest, parserRevision: key.revision,
            now: now, leaseDuration: leaseDuration
        ) else { return nil }
        try requireBorrowed(task)
        try checkDeadline()
        guard let post = usablePolicy(),
              post.parserRevision.utf8.elementsEqual(claimed.parserRevision.utf8) else {
            throw TransactionFence()
        }
        let binding: CaptureIngestSourceBinding
        do {
            binding = try requireBinding(db, claim: claimed, policy: post)
        } catch is NeutralOutcome {
            throw TransactionFence()
        } catch is CaptureIngestSourceRegistryError {
            throw TransactionFence()
        }
        _ = try requireLiveLease(claimed, committed: true)
        return (claimed, binding)
    }

    private func preselect(
        _ db: Database, policy: ServiceCaptureIngestParserPolicy, now: Int64
    ) throws -> (digest: String, revision: String)? {
        let sources = policy.enabledSources.map(\.rawValue).sorted()
        let placeholders = sources.map { _ in "?" }.joined(separator: ",")
        var arguments: [any DatabaseValueConvertible] = sources
        arguments.append(policy.parserRevision)
        arguments.append(now)
        arguments.append(now)
        let sql = """
            SELECT l.publication_sha256, l.parser_revision
            FROM capture_ingest_ledger l
            JOIN capture_ingest_publications p ON p.publication_sha256 = l.publication_sha256
            JOIN capture_ingest_source_registry r
              ON r.machine_id = p.machine_id COLLATE BINARY
             AND r.source_instance_id = p.source_instance_id COLLATE BINARY
             AND r.approved_epoch = p.collector_epoch COLLATE BINARY
             AND r.parse_format IS NOT NULL
             AND r.source IN (\(placeholders))
            JOIN capture_ingest_epoch_history h
              ON h.machine_id = r.machine_id COLLATE BINARY
             AND h.source_instance_id = r.source_instance_id COLLATE BINARY
             AND h.approved_epoch = r.approved_epoch COLLATE BINARY
             AND h.authority_generation = r.authority_generation
            WHERE l.parser_revision = ? COLLATE BINARY
              AND (
                (l.status = 'pending'
                 AND l.claim_token IS NULL AND l.claim_started_at IS NULL
                 AND l.claim_expires_at IS NULL AND l.retry_after IS NULL)
                OR (l.status = 'failed_retryable'
                 AND l.claim_token IS NULL AND l.claim_started_at IS NULL
                 AND l.claim_expires_at IS NULL
                 AND typeof(l.retry_after) = 'integer' AND l.retry_after <= ?)
                OR (l.status = 'processing'
                 AND l.claim_token IS NOT NULL
                 AND typeof(l.claim_expires_at) = 'integer' AND l.claim_expires_at <= ?)
              )
            ORDER BY l.created_at ASC, l.publication_sha256 COLLATE BINARY ASC
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) else {
            return nil
        }
        return (row["publication_sha256"], row["parser_revision"])
    }

    private func requireBinding(
        _ db: Database, claim: CaptureIngestClaim, policy: ServiceCaptureIngestParserPolicy
    ) throws -> CaptureIngestSourceBinding {
        guard let binding = try CaptureIngestSourceRegistry.binding(
            db, machineID: claim.publication.machineID, sourceInstanceID: claim.publication.sourceInstanceID
        ) else { throw NeutralOutcome() }
        guard policy.enabledSources.contains(binding.source),
              binding.approvedEpoch.utf8.elementsEqual(claim.publication.collectorEpoch.utf8) else {
            throw NeutralOutcome()
        }
        let history = try CaptureIngestSourceRegistry.history(
            db, machineID: binding.machineID, sourceInstanceID: binding.sourceInstanceID
        )
        guard history.contains(where: {
            $0.approvedEpoch.utf8.elementsEqual(binding.approvedEpoch.utf8)
                && $0.authorityGeneration == binding.authorityGeneration
        }) else { throw NeutralOutcome() }
        return binding
    }

    private func requireCurrentAuthority(
        _ db: Database, claim: CaptureIngestClaim, binding: CaptureIngestSourceBinding, committed: Bool
    ) throws {
        guard let policy = usablePolicy(),
              policy.parserRevision.utf8.elementsEqual(claim.parserRevision.utf8),
              policy.enabledSources.contains(binding.source) else {
            throw committed ? TransactionFence() : NeutralOutcome()
        }
        let current: CaptureIngestSourceBinding
        do {
            current = try requireBinding(db, claim: claim, policy: policy)
        } catch is NeutralOutcome {
            throw committed ? TransactionFence() : NeutralOutcome()
        }
        guard current == binding else {
            throw committed ? TransactionFence() : NeutralOutcome()
        }
    }

    private func requireLiveLease(_ claim: CaptureIngestClaim, committed: Bool) throws -> Int64 {
        let now = unixClock()
        guard now >= 0 else { throw CaptureIngestLedgerError.invalidTime }
        guard claim.claimedAt <= now, now < claim.expiresAt else {
            throw committed ? TransactionFence() : NeutralOutcome()
        }
        return now
    }

    private func usablePolicy() -> ServiceCaptureIngestParserPolicy? {
        guard let policy = policy(), !policy.enabledSources.isEmpty else { return nil }
        return policy
    }

    private func validateDurations() throws {
        guard (1...300).contains(leaseDuration) else { throw CaptureIngestLedgerError.invalidLeaseDuration }
        guard (1...3_600).contains(retryDelay) else { throw CaptureIngestLedgerError.invalidRetryDelay }
        let now = unixClock()
        guard now >= 0 else { throw CaptureIngestLedgerError.invalidTime }
        let (_, leaseOverflow) = now.addingReportingOverflow(leaseDuration)
        guard !leaseOverflow else { throw CaptureIngestLedgerError.timeOverflow }
        let (_, retryOverflow) = now.addingReportingOverflow(retryDelay)
        guard !retryOverflow else { throw CaptureIngestLedgerError.timeOverflow }
    }

    private func checkFences() throws {
        try Task.checkCancellation()
        try checkDeadline()
    }

    private func checkDeadline() throws {
        if let deadline, ContinuousClock.now >= deadline {
            throw CaptureIngestLedgerError.invalidTime
        }
    }

    private func requireBorrowed(_ task: UnsafeCurrentTask?) throws {
        if task?.isCancelled == true { throw CancellationError() }
        try checkDeadline()
    }

    private func withBorrowedTask<Value>(
        _ body: (UnsafeCurrentTask?) throws -> Value
    ) throws -> Value {
        try withUnsafeCurrentTask { task in
            try body(task)
        }
    }

    private func write<Value: Sendable>(
        _ name: String, _ operation: @escaping @Sendable (EngramDatabaseWriter) throws -> Value
    ) async throws -> Value {
        try await gate.performWriteCommand(name: name, operation: { writer in
            try operation(writer)
        }).value
    }

    private func mapReplay(_ error: CaptureIngestReplayError) -> CaptureIngestWorkFailure {
        switch error {
        case .quarantined(.invalidManifest), .quarantined(.manifestMismatch):
            return .quarantined(.invalidManifest)
        case .quarantined(.unsupportedCaptureShape), .quarantined(.invalidReplayLayout):
            return .quarantined(.unsupportedCaptureShape)
        case .quarantined(.sourceIntegrityMismatch):
            return .quarantined(.sourceIntegrityMismatch)
        case .quarantined(.bindingMismatch), .quarantined(.sourceMismatch):
            return .quarantined(.bindingMismatch)
        case .quarantined(.invalidNativeIdentity):
            return .quarantined(.invalidNativeIdentity)
        case .quarantined(.unsafeStaging):
            return .retryable(.stagingUnavailable)
        case .retryable(.casUnavailable):
            return .retryable(.casUnavailable)
        case .retryable(.stagingUnavailable):
            return .retryable(.stagingUnavailable)
        case .parseFailed(let failure):
            return .parse(failure)
        }
    }

    private func indexedAt(from unix: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}
