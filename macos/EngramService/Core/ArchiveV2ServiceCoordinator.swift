import EngramCoreRead
import EngramCoreWrite
import Foundation
import GRDB

struct ArchiveV2ServiceCaptureSummary: Equatable, Sendable {
    let unsupported: Int
    let unsafe: Int
    let processed: Int
    let capturedSourceBytes: Int64
    let transientRetryLocators: [SourceName: [String]]
    let resolvedRetryLocators: [SourceName: [String]]
    let successfulLocators: [SourceName: [String]]
    let hasMore: Bool

    init(
        unsupported: Int,
        unsafe: Int,
        processed: Int = 0,
        capturedSourceBytes: Int64 = 0,
        transientRetryLocators: [SourceName: [String]] = [:],
        resolvedRetryLocators: [SourceName: [String]] = [:],
        successfulLocators: [SourceName: [String]] = [:],
        hasMore: Bool = false
    ) {
        self.unsupported = unsupported
        self.unsafe = unsafe
        self.processed = processed
        self.capturedSourceBytes = capturedSourceBytes
        self.transientRetryLocators = transientRetryLocators
        self.resolvedRetryLocators = resolvedRetryLocators
        self.successfulLocators = successfulLocators
        self.hasMore = hasMore
    }
}

struct ArchiveV2ServiceIndexPlan: Equatable, Sendable {
    /// `nil` is reserved for the default-off legacy path. A non-nil dictionary
    /// is a strict per-cycle allowlist; an empty dictionary permits no exact
    /// adapter parsing while still allowing non-exact adapters.
    let capturedExactLocators: [SourceName: [String]]?

    static let unrestricted = ArchiveV2ServiceIndexPlan(capturedExactLocators: nil)

    static func captured(
        _ locators: [SourceName: [String]]
    ) -> ArchiveV2ServiceIndexPlan {
        ArchiveV2ServiceIndexPlan(capturedExactLocators: locators)
    }
}

struct ArchiveV2ServiceCycleResult: Equatable, Sendable {
    let indexResult: EngramDatabaseIndexResult
    let indexPlan: ArchiveV2ServiceIndexPlan

    var indexed: Int { indexResult.indexed }
    var total: Int { indexResult.total }
    var todayParents: Int { indexResult.todayParents }
}

struct ArchiveV2ServiceCaptureTarget: Equatable, Sendable {
    let captureID: String
    let source: SourceName
    let locator: String
    let generation: ArchiveSourceGeneration?
    let capturedAt: String
}

struct ArchiveV2ServicePolicyTarget: Equatable, Sendable {
    let manifestSHA256: String
    let captureID: String
    let sessionID: String
    let source: SourceName
    let locator: String
    let boundAt: String
    let historical: Bool
}

struct ArchiveV2ServiceSnapshotRow: Equatable, Sendable {
    let captureID: String
    let sessionID: String
    let source: SourceName
    let locator: String
    let cwd: String
    let trustedIndexState: Bool
    let proof: ArchiveIndexedGenerationProof?
}

struct ArchiveV2ServiceIndexSnapshot: Equatable, Sendable {
    let rows: [ArchiveV2ServiceSnapshotRow]
}

struct ArchiveV2ServiceUnknownPage: Equatable, Sendable {
    let targets: [ArchiveV2ServicePolicyTarget]
}

struct ArchiveV2ServiceCoordinatorOperations: Sendable {
    typealias RemoteTelemetryResults = [
        String: Result<ArchiveRemoteTelemetrySnapshot, any Error>
    ]

    var capture: @Sendable (
        [any SessionAdapter],
        Int,
        ArchiveCaptureCursorScope
    ) async throws -> ArchiveV2ServiceCaptureSummary
    var backlogCapture: @Sendable (
        [any SessionAdapter]
    ) async throws -> ArchiveV2ServiceCaptureSummary
    var bindingTargets: @Sendable (Int) async throws -> [ArchiveV2ServiceCaptureTarget]
    var historicalUnknown: @Sendable (Int) async throws -> ArchiveV2ServiceUnknownPage
    var advancePolicyCursor: @Sendable (ArchiveV2ServicePolicyTarget) async throws -> Void
    var snapshot: @Sendable (
        ServiceWriterGate,
        [ArchiveV2ServiceCaptureTarget]
    ) async throws -> ArchiveV2ServiceIndexSnapshot
    var bindOne: @Sendable (
        ArchiveV2ServiceCaptureTarget,
        [ArchiveSessionIdentity]
    ) async throws -> ArchiveV2ServicePolicyTarget?
    var applyRemotePolicy: @Sendable (
        ArchiveV2ServicePolicyTarget,
        String?,
        ArchiveRemoteEligibility
    ) async throws -> Void
    var replicate: @Sendable (Int) async -> ArchiveReplicationCycleResult
    var replicateBacklog: @Sendable (Int) async -> ArchiveReplicationCycleResult
    var status: @Sendable () async throws -> ArchiveStatusAggregate
    var remoteTelemetry: @Sendable () async -> RemoteTelemetryResults
    var retry: @Sendable (String?) async throws -> Int
    var recoveryDrill: @Sendable (String) async throws -> ArchiveRecoveryLease

    init(
        capture: @escaping @Sendable (
            [any SessionAdapter],
            Int,
            ArchiveCaptureCursorScope
        ) async throws -> ArchiveV2ServiceCaptureSummary,
        backlogCapture: (@Sendable (
            [any SessionAdapter]
        ) async throws -> ArchiveV2ServiceCaptureSummary)? = nil,
        bindingTargets: @escaping @Sendable (Int) async throws -> [ArchiveV2ServiceCaptureTarget],
        historicalUnknown: @escaping @Sendable (Int) async throws -> ArchiveV2ServiceUnknownPage,
        advancePolicyCursor: @escaping @Sendable (ArchiveV2ServicePolicyTarget) async throws -> Void,
        snapshot: @escaping @Sendable (
            ServiceWriterGate,
            [ArchiveV2ServiceCaptureTarget]
        ) async throws -> ArchiveV2ServiceIndexSnapshot,
        bindOne: @escaping @Sendable (
            ArchiveV2ServiceCaptureTarget,
            [ArchiveSessionIdentity]
        ) async throws -> ArchiveV2ServicePolicyTarget?,
        applyRemotePolicy: @escaping @Sendable (
            ArchiveV2ServicePolicyTarget,
            String?,
            ArchiveRemoteEligibility
        ) async throws -> Void,
        replicate: @escaping @Sendable (Int) async -> ArchiveReplicationCycleResult,
        replicateBacklog: (@Sendable (Int) async -> ArchiveReplicationCycleResult)? = nil,
        status: @escaping @Sendable () async throws -> ArchiveStatusAggregate,
        remoteTelemetry: @escaping @Sendable () async -> RemoteTelemetryResults = { [:] },
        retry: @escaping @Sendable (String?) async throws -> Int,
        recoveryDrill: @escaping @Sendable (String) async throws -> ArchiveRecoveryLease = { _ in
            throw ArchiveV2ServiceCoordinatorError.recoveryDrillUnavailable
        }
    ) {
        self.capture = capture
        self.backlogCapture = backlogCapture ?? { adapters in
            try await capture(adapters, 32, .full)
        }
        self.bindingTargets = bindingTargets
        self.historicalUnknown = historicalUnknown
        self.advancePolicyCursor = advancePolicyCursor
        self.snapshot = snapshot
        self.bindOne = bindOne
        self.applyRemotePolicy = applyRemotePolicy
        self.replicate = replicate
        self.replicateBacklog = replicateBacklog ?? replicate
        self.status = status
        self.remoteTelemetry = remoteTelemetry
        self.retry = retry
        self.recoveryDrill = recoveryDrill
    }
}

enum ArchiveV2ServiceCoordinatorError: Error, Equatable, Sendable {
    case invalidReplica
    case recoveryDrillUnavailable
    case noRecoveryDrillCandidate
    case recoveryDrillMismatch
    case recoveryDrillTimedOut
}

actor ArchiveV2ServiceCoordinator {
    typealias TokenLoaderFactory = @Sendable () -> any ArchiveReplicaTokenLoading
    typealias BackendFactory = @Sendable (
        ArchiveReplicaConnection
    ) throws -> any ArchiveReplicaBackend

    private struct InFlightCycle {
        let id: UUID
        let task: Task<ArchiveV2ServiceCycleResult, Error>
    }

    private struct InFlightRecoveryDrill {
        let id: UUID
        let task: Task<ArchiveRecoveryLease, Error>
    }

    private enum PolicyDecision {
        case eligible(String)
        case excluded(String?)
        case leaveUnknown
    }

    private struct ReconcileSummary {
        let boundRows: Int
        let policyRows: Int
        let hasMore: Bool
    }

    private let settings: ArchiveV2Settings
    private let writerGate: ServiceWriterGate
    private let localCaptureReady: Bool
    private let remoteReady: Bool
    private let policySnapshotReady: Bool
    private let configurationError: String?
    private let operations: ArchiveV2ServiceCoordinatorOperations?
    private let batchSize: Int
    private let captureRetryLocatorLimit: Int
    private let now: @Sendable () -> Date
    nonisolated let transcriptResolverSnapshot: ArchiveTranscriptResolver?
    nonisolated let reclamationCoordinatorSnapshot: ArchiveReclamationCoordinator?

    private var inFlight: InFlightCycle?
    private var recoveryDrillsInFlight: [String: InFlightRecoveryDrill] = [:]
    private var cycleCoalesced = false
    private var lastCaptureError: String?
    private var lastReplicationError: String?
    private var unsupportedLocatorCount = 0
    private var unsafeLocatorCount = 0
    private var captureRetryLocators: [SourceName: [String]] = [:]
    private var fullCapturePending = false
    private var lastReplicationCycle: EngramServiceArchiveV2ReplicationCycleSummary?
    private var nextScheduledCycleAt: String?
    private var drainer: ArchiveV2BacklogDrainer?
    private var pipelineBusy = false
    private var indexPipelineWaiters: [CheckedContinuation<Void, Never>] = []
    private var backlogPipelineWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        settings: ArchiveV2Settings,
        writerGate: ServiceWriterGate,
        remoteReady: Bool,
        configurationError: String?,
        operations: ArchiveV2ServiceCoordinatorOperations,
        transcriptResolverSnapshot: ArchiveTranscriptResolver? = nil,
        reclamationCoordinatorSnapshot: ArchiveReclamationCoordinator? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.writerGate = writerGate
        localCaptureReady = settings.exactArchiveEnabled
        self.remoteReady = settings.exactArchiveEnabled && remoteReady
        policySnapshotReady = settings.remoteReplicationEnabled
            && settings.configurationError == nil
        self.configurationError = configurationError
        self.operations = operations
        self.now = now
        self.transcriptResolverSnapshot = transcriptResolverSnapshot
        self.reclamationCoordinatorSnapshot = reclamationCoordinatorSnapshot
        batchSize = settings.remoteConfiguration?.batchSize
            ?? ArchiveV2Settings.defaultBatchSize
        captureRetryLocatorLimit = min(
            max(batchSize, 0),
            Self.maximumCaptureRetryLocatorsPerSource
        )
    }

    private init(
        settings: ArchiveV2Settings,
        writerGate: ServiceWriterGate,
        localCaptureReady: Bool,
        remoteReady: Bool,
        configurationError: String?,
        operations: ArchiveV2ServiceCoordinatorOperations?,
        transcriptResolverSnapshot: ArchiveTranscriptResolver? = nil,
        reclamationCoordinatorSnapshot: ArchiveReclamationCoordinator? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.writerGate = writerGate
        self.localCaptureReady = localCaptureReady
        self.remoteReady = remoteReady
        policySnapshotReady = settings.remoteReplicationEnabled
            && settings.configurationError == nil
        self.configurationError = configurationError
        self.operations = operations
        self.now = now
        self.transcriptResolverSnapshot = transcriptResolverSnapshot
        self.reclamationCoordinatorSnapshot = reclamationCoordinatorSnapshot
        batchSize = settings.remoteConfiguration?.batchSize
            ?? ArchiveV2Settings.defaultBatchSize
        captureRetryLocatorLimit = min(
            max(batchSize, 0),
            Self.maximumCaptureRetryLocatorsPerSource
        )
    }

    nonisolated static func make(
        settings: ArchiveV2Settings,
        databasePath: String,
        writerGate: ServiceWriterGate,
        settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".engram/settings.json"),
        environment: [String: String] = [:],
        tokenLoaderFactory: @escaping TokenLoaderFactory = { ArchiveCredentialStore() },
        backendFactory: @escaping BackendFactory = { HTTPArchiveReplicaBackend(connection: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ArchiveV2ServiceCoordinator {
        guard settings.exactArchiveEnabled else {
            return ArchiveV2ServiceCoordinator(
                settings: settings,
                writerGate: writerGate,
                localCaptureReady: false,
                remoteReady: false,
                configurationError: settings.configurationError?.rawValue,
                operations: nil,
                now: now
            )
        }

        let root = URL(fileURLWithPath: databasePath)
            .deletingLastPathComponent()
            .appendingPathComponent("archive-v2", isDirectory: true)
        let cas: ImmutableArchiveCAS
        let catalog: ArchiveCatalog
        do {
            cas = try ImmutableArchiveCAS(root: root)
            catalog = try ArchiveCatalog(root: root)
            try catalog.migrate()
        } catch {
            return ArchiveV2ServiceCoordinator(
                settings: settings,
                writerGate: writerGate,
                localCaptureReady: false,
                remoteReady: false,
                configurationError: "local_archive_unavailable",
                operations: nil,
                now: now
            )
        }

        let captureCoordinator = ArchiveCaptureCoordinator(
            cas: cas,
            catalog: catalog,
            unboundBatchLimit: max(settings.remoteConfiguration?.batchSize
                ?? ArchiveV2Settings.defaultBatchSize, 1)
        )

        var replicationCoordinator: ArchiveReplicationCoordinator?
        var replicaBackends: [String: any ArchiveReplicaBackend] = [:]
        var resolvedConfigurationError = settings.configurationError?.rawValue
        if settings.configurationError == nil,
           settings.remoteReplicationEnabled,
           let remote = settings.remoteConfiguration {
            do {
                let replicaSet = try ArchiveReplicaSet(
                    descriptors: remote.replicas,
                    tokenLoader: tokenLoaderFactory()
                )
                let backends = try replicaSet.connections.map(backendFactory)
                replicaBackends = Dictionary(
                    uniqueKeysWithValues: backends.map { ($0.replicaID, $0) }
                )
                replicationCoordinator = try ArchiveReplicationCoordinator(
                    catalog: catalog,
                    cas: cas,
                    backends: backends,
                    clock: now
                )
            } catch {
                resolvedConfigurationError = Self.remoteConfigurationSymbol(error)
            }
        }

        let transcriptResolver: ArchiveTranscriptResolver?
        do {
            transcriptResolver = try ArchiveTranscriptResolver(
                catalog: catalog,
                cas: cas,
                hq: replicaBackends["hq"],
                m1: replicaBackends["m1"],
                temporaryParent: root.appendingPathComponent("tmp", isDirectory: true)
            )
        } catch {
            transcriptResolver = nil
            if resolvedConfigurationError == nil {
                resolvedConfigurationError = "local_archive_unavailable"
            }
        }

        let operations = Self.productionOperations(
            captureCoordinator: captureCoordinator,
            catalog: catalog,
            replicationCoordinator: replicationCoordinator,
            transcriptResolver: transcriptResolver,
            replicaBackends: replicaBackends
        )
        let reclamationCoordinator = try? ArchiveReclamationCoordinator(
            settingsURL: settingsURL,
            environment: environment,
            databasePath: databasePath,
            catalog: catalog,
            cas: cas
        )
        return ArchiveV2ServiceCoordinator(
            settings: settings,
            writerGate: writerGate,
            localCaptureReady: true,
            remoteReady: replicationCoordinator != nil,
            configurationError: resolvedConfigurationError,
            operations: operations,
            transcriptResolverSnapshot: transcriptResolver,
            reclamationCoordinatorSnapshot: reclamationCoordinator,
            now: now
        )
    }

    func runCycle(
        adapters: [any SessionAdapter],
        cursorScope: ArchiveCaptureCursorScope,
        indexOperation: @escaping @Sendable (
            ArchiveV2ServiceIndexPlan
        ) async throws -> EngramDatabaseIndexResult
    ) async throws -> ArchiveV2ServiceCycleResult {
        if let inFlight {
            cycleCoalesced = true
            return try await inFlight.task.value
        }

        cycleCoalesced = false
        nextScheduledCycleAt = nil
        let id = UUID()
        let task = Task<ArchiveV2ServiceCycleResult, Error> { [self] in
            try await executeCycle(
                adapters: adapters,
                cursorScope: cursorScope,
                indexOperation: indexOperation
            )
        }
        inFlight = InFlightCycle(id: id, task: task)

        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                clearCycle(id: id)
                return value
            } catch {
                clearCycle(id: id)
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }

    func attachDrainer(_ drainer: ArchiveV2BacklogDrainer) {
        self.drainer = drainer
    }

    func runBacklogPass(
        adapters: [any SessionAdapter]
    ) async throws -> ArchiveV2DrainPassSummary {
        guard localCaptureReady, let operations else {
            return ArchiveV2DrainPassSummary(
                startedAt: now(),
                finishedAt: now()
            )
        }
        await acquirePipeline(indexPriority: false)
        defer { releasePipeline() }

        let startedAt = now()
        let deadline = startedAt.addingTimeInterval(10)
        var capture = ArchiveV2ServiceCaptureSummary(unsupported: 0, unsafe: 0)
        var reconcile = ReconcileSummary(boundRows: 0, policyRows: 0, hasMore: false)
        var replication = ArchiveReplicationCycleResult()

        if now() < deadline {
            await drainer?.setActiveStages([.capture])
            do {
                capture = try await operations.backlogCapture(adapters)
                unsupportedLocatorCount = max(capture.unsupported, 0)
                unsafeLocatorCount = max(capture.unsafe, 0)
                updateCaptureRetryLocators(with: capture)
                fullCapturePending = capture.hasMore
                lastCaptureError = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                fullCapturePending = true
                lastCaptureError = "capture_failure"
            }
        }

        if now() < deadline {
            await drainer?.setActiveStages([.binding])
            reconcile = try await reconcileArchive(
                operations: operations,
                bindingLimit: 100,
                historicalLimit: 100,
                policyLimit: 100,
                reportDrainStages: true
            )
        }

        if remoteReady, now() < deadline {
            await drainer?.setActiveStages([.hq, .m1])
            let replicationStartedAt = now()
            replication = await operations.replicateBacklog(16)
            let replicationFinishedAt = now()
            lastReplicationCycle = Self.replicationCycleSummary(
                result: replication,
                startedAt: replicationStartedAt,
                finishedAt: replicationFinishedAt
            )
            lastReplicationError = replication.cycleError
            if replication.cancelled { throw CancellationError() }
        }

        await drainer?.setActiveStages([])
        let aggregate = try await operations.status()
        let nextRetryAt = Self.earliestRetryDate(aggregate)
        let pausedReplicas = Set(replication.pausedReplicaIDs)
        let hasRunnableWork = capture.hasMore
            || reconcile.hasMore
            || (!pausedReplicas.contains("hq") && aggregate.hq.pending > 0)
            || (!pausedReplicas.contains("m1") && aggregate.m1.pending > 0)
        return ArchiveV2DrainPassSummary(
            startedAt: startedAt,
            finishedAt: now(),
            capturedFiles: capture.processed,
            capturedSourceBytes: capture.capturedSourceBytes,
            boundRows: reconcile.boundRows,
            policyRows: reconcile.policyRows,
            hqVerified: replication.verifiedByReplica["hq"] ?? 0,
            m1Verified: replication.verifiedByReplica["m1"] ?? 0,
            retryScheduled: replication.retryScheduled,
            quarantined: replication.quarantined,
            hasRunnableWork: hasRunnableWork,
            nextRetryAt: nextRetryAt,
            needsAttention: !replication.pausedReplicaIDs.isEmpty
        )
    }

    func status() async -> EngramServiceArchiveV2StatusResponse {
        let aggregate: ArchiveStatusAggregate
        let remoteTelemetry: ArchiveV2ServiceCoordinatorOperations.RemoteTelemetryResults
        let drainSnapshot = await drainer?.snapshot()
        if let operations, localCaptureReady {
            do {
                aggregate = try await operations.status()
            } catch {
                aggregate = Self.zeroAggregate
            }
            remoteTelemetry = remoteReady ? await operations.remoteTelemetry() : [:]
        } else {
            aggregate = Self.zeroAggregate
            remoteTelemetry = [:]
        }
        return Self.statusResponse(
            settings: settings,
            localCaptureReady: localCaptureReady,
            remoteReady: remoteReady,
            configurationError: configurationError,
            aggregate: aggregate,
            remoteTelemetry: remoteTelemetry,
            unsupportedLocatorCount: unsupportedLocatorCount,
            unsafeLocatorCount: unsafeLocatorCount,
            lastCaptureError: lastCaptureError,
            lastReplicationError: lastReplicationError,
            cycleRunning: inFlight != nil,
            cycleCoalesced: cycleCoalesced,
            lastReplicationCycle: lastReplicationCycle,
            nextScheduledCycleAt: nextScheduledCycleAt,
            drainSnapshot: drainSnapshot
        )
    }

    func recordNextScheduledCycle(at date: Date) {
        nextScheduledCycleAt = Self.timestamp(date)
    }

    func retryQuarantined(replicaID: String?) async -> EngramServiceArchiveV2RetryResponse {
        guard replicaID == nil || replicaID == "hq" || replicaID == "m1" else {
            return Self.retryResponse(accepted: false, resetRows: 0, error: "invalid_replica")
        }
        guard localCaptureReady, let operations else {
            return Self.retryResponse(accepted: false, resetRows: 0, error: "archive_v2_disabled")
        }
        do {
            let count = try await operations.retry(replicaID)
            await drainer?.signal()
            return Self.retryResponse(accepted: true, resetRows: count, error: nil)
        } catch is CancellationError {
            return Self.retryResponse(accepted: false, resetRows: 0, error: "cancelled")
        } catch {
            return Self.retryResponse(accepted: false, resetRows: 0, error: "catalog_failure")
        }
    }

    func runRecoveryDrill(replicaID: String) async throws -> ArchiveRecoveryLease {
        guard replicaID == "hq" || replicaID == "m1" else {
            throw ArchiveV2ServiceCoordinatorError.invalidReplica
        }
        guard remoteReady, let operations else {
            throw ArchiveV2ServiceCoordinatorError.recoveryDrillUnavailable
        }
        if let existing = recoveryDrillsInFlight[replicaID] {
            return try await existing.task.value
        }
        let id = UUID()
        let task = Task { try await operations.recoveryDrill(replicaID) }
        recoveryDrillsInFlight[replicaID] = InFlightRecoveryDrill(id: id, task: task)
        do {
            let lease = try await task.value
            clearRecoveryDrill(replicaID: replicaID, id: id)
            return lease
        } catch {
            clearRecoveryDrill(replicaID: replicaID, id: id)
            throw error
        }
    }

    private func clearRecoveryDrill(replicaID: String, id: UUID) {
        guard recoveryDrillsInFlight[replicaID]?.id == id else { return }
        recoveryDrillsInFlight.removeValue(forKey: replicaID)
    }

    func recentCaptureRetryLocators(
        maximumPerSource: Int
    ) -> [SourceName: [String]] {
        let limit = min(
            max(maximumPerSource, 0),
            captureRetryLocatorLimit,
            Self.maximumCaptureRetryLocatorsPerSource
        )
        guard limit > 0 else { return [:] }

        var result: [SourceName: [String]] = [:]
        for source in SourceName.allCases {
            guard let locators = captureRetryLocators[source], !locators.isEmpty else {
                continue
            }
            result[source] = Array(locators.prefix(limit))
        }
        return result
    }

    func needsFullCaptureContinuation() -> Bool {
        localCaptureReady && drainer == nil && fullCapturePending
    }

    private func executeCycle(
        adapters: [any SessionAdapter],
        cursorScope: ArchiveCaptureCursorScope,
        indexOperation: @escaping @Sendable (
            ArchiveV2ServiceIndexPlan
        ) async throws -> EngramDatabaseIndexResult
    ) async throws -> ArchiveV2ServiceCycleResult {
        guard localCaptureReady, let operations else {
            let result = try await indexOperation(.unrestricted)
            return ArchiveV2ServiceCycleResult(
                indexResult: result,
                indexPlan: .unrestricted
            )
        }
        await acquirePipeline(indexPriority: true)
        defer { releasePipeline() }

        var indexPlan = ArchiveV2ServiceIndexPlan.captured([:])
        do {
            let summary = try await operations.capture(adapters, batchSize, cursorScope)
            unsupportedLocatorCount = max(summary.unsupported, 0)
            unsafeLocatorCount = max(summary.unsafe, 0)
            updateCaptureRetryLocators(with: summary)
            indexPlan = .captured(summary.successfulLocators)
            if cursorScope == .full {
                fullCapturePending = summary.hasMore
            }
            lastCaptureError = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if cursorScope == .full {
                fullCapturePending = true
            }
            lastCaptureError = "capture_failure"
        }

        try Task.checkCancellation()
        let indexResult = try await indexOperation(indexPlan)
        try Task.checkCancellation()

        do {
            _ = try await reconcileArchive(
                operations: operations,
                bindingLimit: batchSize,
                historicalLimit: policySnapshotReady ? max(1, batchSize / 2) : 0,
                policyLimit: batchSize
            )
            if remoteReady, drainer == nil {
                let replicationStartedAt = now()
                let replication = await operations.replicate(batchSize)
                let replicationFinishedAt = now()
                lastReplicationCycle = Self.replicationCycleSummary(
                    result: replication,
                    startedAt: replicationStartedAt,
                    finishedAt: replicationFinishedAt
                )
                if let summary = lastReplicationCycle {
                    ServiceLogger.info(
                        "archive v2 replication cycle completed "
                            + "duration_ms=\(Int(summary.durationMs.rounded())) "
                            + "claimed=\(summary.claimedCount) "
                            + "verified=\(summary.verifiedCount) "
                            + "retry=\(summary.retryScheduledCount) "
                            + "quarantined=\(summary.quarantinedCount) "
                            + "cancelled=\(summary.cancelled) "
                            + "error=\(summary.cycleError ?? "none")",
                        category: .runner
                    )
                }
                if replication.cancelled { throw CancellationError() }
                lastReplicationError = replication.cycleError
            }
            await drainer?.signal()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if lastCaptureError == nil {
                lastCaptureError = "archive_reconcile_failure"
            }
        }

        return ArchiveV2ServiceCycleResult(
            indexResult: indexResult,
            indexPlan: indexPlan
        )
    }

    private func reconcileArchive(
        operations: ArchiveV2ServiceCoordinatorOperations,
        bindingLimit: Int,
        historicalLimit: Int,
        policyLimit: Int,
        reportDrainStages: Bool = false
    ) async throws -> ReconcileSummary {
        let bindingTargets = try await operations.bindingTargets(bindingLimit)
        let historicalPage = policySnapshotReady
            ? try await operations.historicalUnknown(historicalLimit)
            : ArchiveV2ServiceUnknownPage(targets: [])
        let historicalCaptureTargets = historicalPage.targets.map {
            ArchiveV2ServiceCaptureTarget(
                captureID: $0.captureID,
                source: $0.source,
                locator: $0.locator,
                generation: nil,
                capturedAt: $0.boundAt
            )
        }
        let snapshotTargets = Self.uniqueTargets(bindingTargets + historicalCaptureTargets)
        let snapshot = try await operations.snapshot(writerGate, snapshotTargets)
        try Task.checkCancellation()

        var newlyBound: [ArchiveV2ServicePolicyTarget] = []
        for target in bindingTargets.prefix(bindingLimit) {
            try Task.checkCancellation()
            let identities = Self.identities(for: target, snapshot: snapshot)
            if let bound = try await operations.bindOne(target, identities) {
                newlyBound.append(bound)
            }
        }

        var appliedPolicy = 0
        if policySnapshotReady {
            if reportDrainStages {
                await drainer?.setActiveStages([.policy])
            }
            var remainingPolicyBudget = policyLimit
            for target in historicalPage.targets.prefix(remainingPolicyBudget) {
                try Task.checkCancellation()
                try await applyPolicy(target, snapshot: snapshot, operations: operations)
                try await operations.advancePolicyCursor(target)
                remainingPolicyBudget -= 1
                appliedPolicy += 1
            }
            for target in newlyBound.prefix(remainingPolicyBudget) {
                try Task.checkCancellation()
                try await applyPolicy(target, snapshot: snapshot, operations: operations)
                appliedPolicy += 1
            }
        }
        return ReconcileSummary(
            boundRows: newlyBound.count,
            policyRows: appliedPolicy,
            hasMore: (bindingLimit > 0 && bindingTargets.count >= bindingLimit)
                || (historicalLimit > 0 && historicalPage.targets.count >= historicalLimit)
                || (policySnapshotReady
                    && historicalPage.targets.count + newlyBound.count > appliedPolicy)
        )
    }

    private func acquirePipeline(indexPriority: Bool) async {
        if !pipelineBusy {
            pipelineBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            if indexPriority {
                indexPipelineWaiters.append(continuation)
            } else {
                backlogPipelineWaiters.append(continuation)
            }
        }
    }

    private func releasePipeline() {
        if !indexPipelineWaiters.isEmpty {
            indexPipelineWaiters.removeFirst().resume()
        } else if !backlogPipelineWaiters.isEmpty {
            backlogPipelineWaiters.removeFirst().resume()
        } else {
            pipelineBusy = false
        }
    }

    private func updateCaptureRetryLocators(
        with summary: ArchiveV2ServiceCaptureSummary
    ) {
        guard captureRetryLocatorLimit > 0 else {
            captureRetryLocators = [:]
            return
        }

        for source in SourceName.allCases {
            var locators = captureRetryLocators[source] ?? []
            let resolved: Set<String> = Set(
                (summary.resolvedRetryLocators[source] ?? []).compactMap { locator in
                    guard let normalized = ArchiveLocatorClassifier.normalize(locator),
                          normalized == locator else {
                        return nil
                    }
                    return normalized
                }
            )
            if !resolved.isEmpty {
                locators.removeAll { resolved.contains($0) }
            }

            var seen = Set(locators)
            for locator in summary.transientRetryLocators[source] ?? [] {
                guard locators.count < captureRetryLocatorLimit,
                      let normalized = ArchiveLocatorClassifier.normalize(locator),
                      normalized == locator,
                      !resolved.contains(normalized),
                      seen.insert(locator).inserted else {
                    continue
                }
                locators.append(locator)
            }

            if locators.isEmpty {
                captureRetryLocators.removeValue(forKey: source)
            } else {
                captureRetryLocators[source] = locators
            }
        }
    }

    private func applyPolicy(
        _ target: ArchiveV2ServicePolicyTarget,
        snapshot: ArchiveV2ServiceIndexSnapshot,
        operations: ArchiveV2ServiceCoordinatorOperations
    ) async throws {
        switch Self.policyDecision(target: target, snapshot: snapshot, settings: settings) {
        case .eligible(let root):
            try await operations.applyRemotePolicy(target, root, .eligible)
        case .excluded(let root):
            try await operations.applyRemotePolicy(target, root, .excluded)
        case .leaveUnknown:
            break
        }
    }

    private func clearCycle(id: UUID) {
        guard inFlight?.id == id else { return }
        inFlight = nil
    }

    private static func identities(
        for target: ArchiveV2ServiceCaptureTarget,
        snapshot: ArchiveV2ServiceIndexSnapshot
    ) -> [ArchiveSessionIdentity] {
        snapshot.rows.compactMap { row in
            guard row.captureID == target.captureID,
                  row.source == target.source,
                  row.locator == target.locator,
                  let proof = row.proof else {
                return nil
            }
            return try? ArchiveSessionIdentity(
                sessionID: row.sessionID,
                source: row.source,
                locator: row.locator,
                indexedGenerationProof: proof
            )
        }
    }

    private static func policyDecision(
        target: ArchiveV2ServicePolicyTarget,
        snapshot: ArchiveV2ServiceIndexSnapshot,
        settings: ArchiveV2Settings
    ) -> PolicyDecision {
        let matches = snapshot.rows.filter {
            $0.source == target.source
                && $0.locator == target.locator
                && $0.sessionID == target.sessionID
        }
        guard matches.count == 1, matches[0].trustedIndexState else {
            return .leaveUnknown
        }
        guard let root = normalizedProjectRoot(matches[0].cwd) else {
            return .excluded(nil)
        }
        return settings.isProjectExcluded(root) ? .excluded(root) : .eligible(root)
    }

    private static func normalizedProjectRoot(_ value: String) -> String? {
        guard !value.isEmpty,
              value != "/",
              value.hasPrefix("/"),
              !value.utf8.contains(0) else {
            return nil
        }
        let normalized = URL(fileURLWithPath: value).standardizedFileURL.path
        guard normalized == value,
              value == "/" || !value.hasSuffix("/") else {
            return nil
        }
        return normalized
    }

    private static func uniqueTargets(
        _ targets: [ArchiveV2ServiceCaptureTarget]
    ) -> [ArchiveV2ServiceCaptureTarget] {
        var seen = Set<String>()
        return targets.filter { seen.insert($0.captureID).inserted }
    }

    private static func productionOperations(
        captureCoordinator: ArchiveCaptureCoordinator,
        catalog: ArchiveCatalog,
        replicationCoordinator: ArchiveReplicationCoordinator?,
        transcriptResolver: ArchiveTranscriptResolver?,
        replicaBackends: [String: any ArchiveReplicaBackend]
    ) -> ArchiveV2ServiceCoordinatorOperations {
        ArchiveV2ServiceCoordinatorOperations(
            capture: { adapters, budget, scope in
                let result = try await captureCoordinator.capture(
                    adapters: adapters,
                    locatorBudget: budget,
                    cursorScope: scope
                )
                return Self.captureSummary(from: result)
            },
            backlogCapture: { adapters in
                let result = try await captureCoordinator.capture(
                    adapters: adapters,
                    budget: ArchiveCaptureBudget(
                        locatorLimit: 32,
                        sourceByteLimit: 128 * 1_024 * 1_024
                    ),
                    cursorScope: .full,
                    refreshLocatorSnapshot: false
                )
                return Self.captureSummary(from: result)
            },
            bindingTargets: { budget in
                try await captureCoordinator.bindingTargets(rowBudget: budget).compactMap(
                    Self.captureTarget
                )
            },
            historicalUnknown: { budget in
                try Self.loadHistoricalUnknownPage(catalog: catalog, limit: budget)
            },
            advancePolicyCursor: { target in
                try Self.storePolicyCursor(catalog: catalog, target: target)
            },
            snapshot: { gate, targets in
                try await Self.readIndexSnapshot(gate: gate, targets: targets)
            },
            bindOne: { _, identities in
                let result = try await captureCoordinator.bind(identities, rowBudget: 1)
                guard let binding = result.bindings.first,
                      let capture = try catalog.capture(captureID: binding.captureID),
                      let source = SourceName(rawValue: capture.source),
                      let locator = ArchiveLocatorClassifier.normalize(capture.locator) else {
                    return nil
                }
                return ArchiveV2ServicePolicyTarget(
                    manifestSHA256: binding.manifestSHA256,
                    captureID: binding.captureID,
                    sessionID: binding.sessionID,
                    source: source,
                    locator: locator,
                    boundAt: binding.boundAt,
                    historical: false
                )
            },
            applyRemotePolicy: { target, root, eligibility in
                _ = try catalog.setRemotePolicySnapshot(
                    manifestSHA256: target.manifestSHA256,
                    projectRootSnapshot: root,
                    eligibility: eligibility
                )
            },
            replicate: { limit in
                guard let replicationCoordinator else {
                    return ArchiveReplicationCycleResult()
                }
                return await replicationCoordinator.runOnce(limit: limit)
            },
            replicateBacklog: { limit in
                guard let replicationCoordinator else {
                    return ArchiveReplicationCycleResult()
                }
                return await replicationCoordinator.runBacklogPass(
                    perReplicaLimit: limit
                )
            },
            status: { try catalog.archiveStatus() },
            remoteTelemetry: {
                async let hq = remoteTelemetryResult(
                    replicaID: "hq",
                    backend: replicaBackends["hq"]
                )
                async let m1 = remoteTelemetryResult(
                    replicaID: "m1",
                    backend: replicaBackends["m1"]
                )
                return Dictionary(uniqueKeysWithValues: await [hq, m1].compactMap { $0 })
            },
            retry: { replicaID in
                let count = try catalog.retryQuarantined(
                    replicaID: replicaID,
                    now: Self.timestamp(Date())
                )
                await replicationCoordinator?.resumeAfterAttention(
                    replicaID: replicaID
                )
                return count
            },
            recoveryDrill: { replicaID in
                try await Self.executeRecoveryDrill(
                    catalog: catalog,
                    transcriptResolver: transcriptResolver,
                    replicaID: replicaID
                )
            }
        )
    }

    static func executeRecoveryDrill(
        catalog: ArchiveCatalog,
        transcriptResolver: ArchiveTranscriptResolver?,
        replicaID: String,
        timeout: Duration = .seconds(60)
    ) async throws -> ArchiveRecoveryLease {
        guard let transcriptResolver else {
            throw ArchiveV2ServiceCoordinatorError.recoveryDrillUnavailable
        }
        guard let candidate = try catalog.nextRecoveryDrillCandidate(
            replicaID: replicaID,
            maximumBytes: 64 * 1_024 * 1_024
        ) else {
            throw ArchiveV2ServiceCoordinatorError.noRecoveryDrillCandidate
        }
        let proof: ArchiveRemoteRecoveryProof
        do {
            proof = try await withThrowingTaskGroup(
                of: ArchiveRemoteRecoveryProof.self
            ) { group in
                group.addTask {
                    try await transcriptResolver.remoteRecoveryProbe(
                        sessionID: candidate.binding.sessionID,
                        replicaID: replicaID
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ArchiveV2ServiceCoordinatorError.recoveryDrillTimedOut
                }
                guard let first = try await group.next() else {
                    throw ArchiveV2ServiceCoordinatorError.recoveryDrillUnavailable
                }
                group.cancelAll()
                return first
            }
            guard proof.tier.rawValue == replicaID,
                  proof.manifestSHA256 == candidate.binding.manifestSHA256,
                  proof.rawByteCount == candidate.rawByteCount else {
                throw ArchiveV2ServiceCoordinatorError.recoveryDrillMismatch
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try catalog.expireRecoveryLeaseAndAdvanceCursor(
                replicaID: replicaID,
                manifestSHA256: candidate.binding.manifestSHA256,
                failedAt: Self.timestamp(Date())
            )
            throw error
        }
        return try catalog.recordRecoveryLeaseAndAdvanceCursor(
            replicaID: replicaID,
            manifestSHA256: proof.manifestSHA256,
            verifiedAt: Self.timestamp(Date()),
            verifiedBytes: proof.rawByteCount
        )
    }

    static func captureSummary(
        from result: ArchiveCaptureCycleResult
    ) -> ArchiveV2ServiceCaptureSummary {
        var unsupported = 0
        var unsafe = 0
        var transientRetryLocators: [SourceName: [String]] = [:]
        var resolvedRetryLocators: [SourceName: [String]] = [:]
        var successfulLocators: [SourceName: [String]] = [:]

        for item in result.items {
            switch item.classification {
            case .unsupportedAdapter, .unsupportedComposite, .unsupportedVirtual:
                unsupported += 1
                appendStableLocator(
                    item.locator,
                    source: item.source,
                    to: &resolvedRetryLocators
                )
            case .missing:
                unsafe += 1
                appendStableLocator(
                    item.locator,
                    source: item.source,
                    to: &transientRetryLocators
                )
            case .unsafe:
                unsafe += 1
                appendStableLocator(
                    item.locator,
                    source: item.source,
                    to: &resolvedRetryLocators
                )
            case .declaredSingleFile:
                if item.captureID != nil {
                    appendStableLocator(
                        item.locator,
                        source: item.source,
                        to: &resolvedRetryLocators
                    )
                    appendStableLocator(
                        item.locator,
                        source: item.source,
                        to: &successfulLocators
                    )
                } else if item.diagnostic != nil {
                    unsafe += 1
                    appendStableLocator(
                        item.locator,
                        source: item.source,
                        to: &transientRetryLocators
                    )
                } else {
                    appendStableLocator(
                        item.locator,
                        source: item.source,
                        to: &resolvedRetryLocators
                    )
                }
            }
        }

        return ArchiveV2ServiceCaptureSummary(
            unsupported: unsupported,
            unsafe: unsafe,
            processed: result.processed,
            capturedSourceBytes: result.capturedSourceBytes,
            transientRetryLocators: transientRetryLocators,
            resolvedRetryLocators: resolvedRetryLocators,
            successfulLocators: successfulLocators,
            hasMore: result.hasMore
        )
    }

    private static func appendStableLocator(
        _ locator: String,
        source: SourceName,
        to locatorsBySource: inout [SourceName: [String]]
    ) {
        guard let normalized = ArchiveLocatorClassifier.normalize(locator),
              normalized == locator else {
            return
        }
        var locators = locatorsBySource[source] ?? []
        guard !locators.contains(normalized) else { return }
        locators.append(normalized)
        locatorsBySource[source] = locators
    }

    static func readIndexSnapshot(
        gate: ServiceWriterGate,
        targets: [ArchiveV2ServiceCaptureTarget]
    ) async throws -> ArchiveV2ServiceIndexSnapshot {
        guard !targets.isEmpty else {
            _ = try await gate.performReadCommand(name: "archiveV2Snapshot") { _ in () }
            return ArchiveV2ServiceIndexSnapshot(rows: [])
        }
        return try await gate.performReadCommand(name: "archiveV2Snapshot") { writer in
            try writer.read { db in
                try buildIndexSnapshot(db: db, targets: targets)
            }
        }.value
    }

    private static func buildIndexSnapshot(
        db: Database,
        targets: [ArchiveV2ServiceCaptureTarget]
    ) throws -> ArchiveV2ServiceIndexSnapshot {
        var result: [ArchiveV2ServiceSnapshotRow] = []
        let grouped = Dictionary(grouping: targets, by: \.source)
        for (source, sourceTargets) in grouped {
            let locators = Array(Set(sourceTargets.map(\.locator))).sorted()
            guard !locators.isEmpty else { continue }
            for offset in stride(from: 0, to: locators.count, by: 400) {
                let slice = Array(locators[offset ..< min(offset + 400, locators.count)])
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
                var arguments: StatementArguments = [source.rawValue]
                for locator in slice { arguments += [locator] }

                let stateRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT source, locator, size_bytes, mtime_ns, inode, device,
                           parsed_offset, boundary_hash, parse_status, failure_kind,
                           retry_after, retry_count, last_error, schema_version, updated_at
                    FROM file_index_state
                    WHERE source = ? AND locator IN (\(placeholders))
                    """,
                    arguments: arguments
                )
                var states: [String: FileIndexState] = [:]
                for row in stateRows {
                    guard let rawStatus = row["parse_status"] as String?,
                          let parseStatus = FileIndexParseStatus(rawValue: rawStatus),
                          let locator = row["locator"] as String? else {
                        continue
                    }
                    states[locator] = FileIndexState(
                        source: source,
                        locator: locator,
                        sizeBytes: row["size_bytes"],
                        modifiedAtNanos: row["mtime_ns"],
                        inode: row["inode"],
                        device: row["device"],
                        parsedOffset: row["parsed_offset"],
                        boundaryHash: row["boundary_hash"],
                        parseStatus: parseStatus,
                        failureKind: (row["failure_kind"] as String?).flatMap(ParserFailure.init(rawValue:)),
                        retryAfterEpochSeconds: row["retry_after"],
                        retryCount: row["retry_count"],
                        lastError: row["last_error"],
                        schemaVersion: row["schema_version"],
                        updatedAtEpochSeconds: row["updated_at"]
                    )
                }

                let sessionRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, source, cwd,
                           COALESCE(NULLIF(source_locator, ''), NULLIF(file_path, '')) AS locator
                    FROM sessions
                    WHERE source = ?
                      AND COALESCE(NULLIF(source_locator, ''), NULLIF(file_path, '')) IN (\(placeholders))
                    ORDER BY id ASC
                    """,
                    arguments: arguments
                )
                for target in sourceTargets where slice.contains(target.locator) {
                    let state = states[target.locator]
                    let freshStat = FileIndexStat.directFileStat(locator: target.locator)
                    let captureMatchesFreshStat = target.generation.flatMap { generation in
                        freshStat.map { stat in
                            generation.size == stat.sizeBytes
                                && generation.inode == stat.inode
                                && generation.device == stat.device
                                && fileManagerPrecisionNanos(generation.mtimeNs)
                                == stat.modifiedAtNanos
                        }
                    } == true
                    let trusted = state?.schemaVersion == FileIndexState.currentSchemaVersion
                        && state?.parseStatus.rawValue == FileIndexParseStatus.ok.rawValue
                        && state?.inode != nil
                        && state?.device != nil
                        && freshStat.map { state?.sameFileIdentity(as: $0) == true } == true
                        && captureMatchesFreshStat
                    let proof: ArchiveIndexedGenerationProof?
                    if trusted, let generation = target.generation {
                        proof = try? ArchiveIndexedGenerationProof(
                            expectedCaptureID: target.captureID,
                            source: target.source,
                            locator: target.locator,
                            sizeBytes: generation.size,
                            modifiedAtNanos: generation.mtimeNs,
                            inode: generation.inode,
                            device: generation.device,
                            parseStatus: .ok
                        )
                    } else {
                        proof = nil
                    }
                    for row in sessionRows where (row["locator"] as String?) == target.locator {
                        guard let sessionID = row["id"] as String? else { continue }
                        result.append(
                            ArchiveV2ServiceSnapshotRow(
                                captureID: target.captureID,
                                sessionID: sessionID,
                                source: target.source,
                                locator: target.locator,
                                cwd: row["cwd"] as String? ?? "",
                                trustedIndexState: trusted,
                                proof: proof
                            )
                        )
                    }
                }
            }
        }
        return ArchiveV2ServiceIndexSnapshot(rows: result)
    }

    /// `file_index_state` and `FileIndexStat` originate from
    /// `FileManager.modificationDate`, whose `Date` representation loses a few
    /// low nanosecond bits at current Unix epochs. Normalize the exact Darwin
    /// timestamp through that same precision domain before comparing it, while
    /// keeping size/device/inode exact.
    private static func fileManagerPrecisionNanos(_ exactNanos: Int64) -> Int64 {
        Int64(
            (
                TimeInterval(exactNanos) / 1_000_000_000
                    * 1_000_000_000
            ).rounded()
        )
    }

    private struct PersistedPolicyCursor: Codable, Equatable {
        let boundAt: String
        let manifestSHA256: String

        init(_ cursor: ArchiveBindingCursor) {
            boundAt = cursor.boundAt
            manifestSHA256 = cursor.manifestSHA256
        }

        var value: ArchiveBindingCursor {
            ArchiveBindingCursor(
                boundAt: boundAt,
                manifestSHA256: manifestSHA256
            )
        }
    }

    private struct PolicyCursorPayload: Codable, Equatable {
        let schemaVersion: Int
        var boundary: PersistedPolicyCursor?
        var after: PersistedPolicyCursor?
    }

    static func loadHistoricalUnknownPage(
        catalog: ArchiveCatalog,
        limit: Int
    ) throws -> ArchiveV2ServiceUnknownPage {
        guard limit > 0 else {
            throw ArchiveCatalogError.invalidLimit(limit)
        }
        var progress = try loadPolicyProgress(catalog: catalog)
        if progress.boundary == nil {
            progress.boundary = try catalog.unknownBindingBoundary().map(
                PersistedPolicyCursor.init
            )
            progress.after = nil
            try storePolicyProgress(catalog: catalog, progress: progress)
        }
        guard let boundary = progress.boundary?.value else {
            return ArchiveV2ServiceUnknownPage(targets: [])
        }
        let bindings = try catalog.unknownBindings(
            limit: limit,
            after: progress.after?.value,
            through: boundary
        )
        guard !bindings.isEmpty else {
            // End this frozen sweep without immediately starting another one in
            // the same call. The next bounded cycle snapshots a fresh tail and
            // revisits every still-unknown row from the beginning.
            try storePolicyProgress(
                catalog: catalog,
                progress: PolicyCursorPayload(
                    schemaVersion: 2,
                    boundary: nil,
                    after: nil
                )
            )
            return ArchiveV2ServiceUnknownPage(targets: [])
        }
        var targets: [ArchiveV2ServicePolicyTarget] = []
        for binding in bindings {
            let capture: ArchiveCapture?
            do {
                capture = try catalog.capture(captureID: binding.captureID)
            } catch is ArchiveCatalogError {
                guard targets.isEmpty else { break }
                try advancePolicyCursor(
                    catalog: catalog,
                    cursor: ArchiveBindingCursor(
                        boundAt: binding.boundAt,
                        manifestSHA256: binding.manifestSHA256
                    )
                )
                continue
            }
            guard let capture,
                  let source = SourceName(rawValue: capture.source),
                  let locator = ArchiveLocatorClassifier.normalize(capture.locator) else {
                guard targets.isEmpty else { break }
                try advancePolicyCursor(
                    catalog: catalog,
                    cursor: ArchiveBindingCursor(
                        boundAt: binding.boundAt,
                        manifestSHA256: binding.manifestSHA256
                    )
                )
                continue
            }
            targets.append(
                ArchiveV2ServicePolicyTarget(
                    manifestSHA256: binding.manifestSHA256,
                    captureID: binding.captureID,
                    sessionID: binding.sessionID,
                    source: source,
                    locator: locator,
                    boundAt: binding.boundAt,
                    historical: true
                )
            )
        }
        return ArchiveV2ServiceUnknownPage(targets: targets)
    }

    private static func loadPolicyProgress(
        catalog: ArchiveCatalog
    ) throws -> PolicyCursorPayload {
        guard let checkpoint = try catalog.archiveCursorCheckpoint(for: .policyCycle) else {
            return PolicyCursorPayload(
                schemaVersion: 2,
                boundary: nil,
                after: nil
            )
        }
        let payload = try ArchiveCanonicalJSON.decode(
            PolicyCursorPayload.self,
            from: checkpoint.payload
        )
        guard payload.schemaVersion == 2,
              payload.boundary != nil || payload.after == nil,
              validPolicyCursor(payload.boundary),
              validPolicyCursor(payload.after),
              try ArchiveCanonicalJSON.encode(payload) == checkpoint.payload else {
            throw ArchiveCatalogError.invalidArchiveCursorCheckpoint(
                ArchiveCursorKey.policyCycle.rawValue
            )
        }
        if let after = payload.after?.value,
           let boundary = payload.boundary?.value,
           (after.boundAt, after.manifestSHA256)
            > (boundary.boundAt, boundary.manifestSHA256) {
            throw ArchiveCatalogError.invalidArchiveCursorCheckpoint(
                ArchiveCursorKey.policyCycle.rawValue
            )
        }
        return payload
    }

    static func storePolicyCursor(
        catalog: ArchiveCatalog,
        target: ArchiveV2ServicePolicyTarget
    ) throws {
        try advancePolicyCursor(
            catalog: catalog,
            cursor: ArchiveBindingCursor(
                boundAt: target.boundAt,
                manifestSHA256: target.manifestSHA256
            )
        )
    }

    private static func advancePolicyCursor(
        catalog: ArchiveCatalog,
        cursor: ArchiveBindingCursor
    ) throws {
        var progress = try loadPolicyProgress(catalog: catalog)
        guard let boundary = progress.boundary?.value,
              (cursor.boundAt, cursor.manifestSHA256)
                <= (boundary.boundAt, boundary.manifestSHA256) else {
            throw ArchiveCatalogError.invalidArchiveCursorCheckpoint(
                ArchiveCursorKey.policyCycle.rawValue
            )
        }
        progress.after = PersistedPolicyCursor(cursor)
        try storePolicyProgress(catalog: catalog, progress: progress)
    }

    private static func storePolicyProgress(
        catalog: ArchiveCatalog,
        progress: PolicyCursorPayload
    ) throws {
        let payload = try ArchiveCanonicalJSON.encode(progress)
        _ = try catalog.storeArchiveCursorCheckpoint(
            payload,
            for: .policyCycle
        )
    }

    private static func validPolicyCursor(
        _ cursor: PersistedPolicyCursor?
    ) -> Bool {
        guard let cursor else { return true }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return ArchiveV2Hash.isValidSHA256(cursor.manifestSHA256)
            && formatter.date(from: cursor.boundAt).map(formatter.string(from:))
                == cursor.boundAt
    }

    private static func captureTarget(_ capture: ArchiveCapture) -> ArchiveV2ServiceCaptureTarget? {
        guard let source = SourceName(rawValue: capture.source),
              let locator = ArchiveLocatorClassifier.normalize(capture.locator) else {
            return nil
        }
        return ArchiveV2ServiceCaptureTarget(
            captureID: capture.captureID,
            source: source,
            locator: locator,
            generation: capture.generation,
            capturedAt: capture.capturedAt
        )
    }

    private static func remoteConfigurationSymbol(_ error: Error) -> String {
        switch error {
        case ArchiveReplicaConfigurationError.missingToken,
             ArchiveReplicaConfigurationError.emptyToken,
             ArchiveReplicaConfigurationError.duplicateToken,
             ArchiveReplicaConfigurationError.credentialFailure,
             is ArchiveCredentialStoreError:
            "remote_credentials_unavailable"
        default:
            "remote_configuration_unavailable"
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func earliestRetryDate(_ aggregate: ArchiveStatusAggregate) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return [aggregate.hq.nextRetryAt, aggregate.m1.nextRetryAt]
            .compactMap { $0.flatMap(formatter.date(from:)) }
            .min()
    }

    private static let maximumCaptureRetryLocatorsPerSource = 100

    private static let zeroAggregate: ArchiveStatusAggregate = {
        let zero = ArchiveReplicaStatusCounts(
            pending: 0,
            inflight: 0,
            retry: 0,
            quarantine: 0,
            verified: 0
        )
        return ArchiveStatusAggregate(
            captured: 0,
            bound: 0,
            unbound: 0,
            unknown: 0,
            eligible: 0,
            excluded: 0,
            hq: zero,
            m1: zero,
            singleVerified: 0,
            dualVerified: 0,
            latestReceipts: []
        )
    }()

    private static func statusResponse(
        settings: ArchiveV2Settings,
        localCaptureReady: Bool,
        remoteReady: Bool,
        configurationError: String?,
        aggregate: ArchiveStatusAggregate,
        remoteTelemetry: ArchiveV2ServiceCoordinatorOperations.RemoteTelemetryResults,
        unsupportedLocatorCount: Int,
        unsafeLocatorCount: Int,
        lastCaptureError: String?,
        lastReplicationError: String?,
        cycleRunning: Bool,
        cycleCoalesced: Bool,
        lastReplicationCycle: EngramServiceArchiveV2ReplicationCycleSummary?,
        nextScheduledCycleAt: String?,
        drainSnapshot: ArchiveV2DrainSnapshot?
    ) -> EngramServiceArchiveV2StatusResponse {
        let replicas = [
            replicaStatus(id: "hq", counts: aggregate.hq, remote: remoteTelemetry["hq"]),
            replicaStatus(id: "m1", counts: aggregate.m1, remote: remoteTelemetry["m1"]),
        ]
        let receipts = aggregate.latestReceipts.compactMap { receipt in
            try? EngramServiceArchiveV2LatestReceipt(
                replicaID: receipt.replicaID,
                manifestSHA256: receipt.manifestSHA256,
                receiptSHA256: receipt.receiptSHA256,
                verifiedAt: receipt.verifiedAt
            )
        }.sorted { $0.replicaID < $1.replicaID }
        return try! EngramServiceArchiveV2StatusResponse(
            enabled: settings.exactArchiveEnabled,
            localCaptureEnabled: localCaptureReady,
            remoteReplicationEnabled: remoteReady,
            configurationError: configurationError,
            capturedCount: aggregate.captured,
            boundCount: aggregate.bound,
            unboundCount: aggregate.unbound,
            remotePolicyUnknownCount: aggregate.unknown,
            remotePolicyEligibleCount: aggregate.eligible,
            remotePolicyExcludedCount: aggregate.excluded,
            unsupportedLocatorCount: max(unsupportedLocatorCount, 0),
            unsafeLocatorCount: max(unsafeLocatorCount, 0),
            replicas: replicas,
            singleReplicaVerifiedCount: aggregate.singleVerified,
            dualReplicaVerifiedCount: aggregate.dualVerified,
            latestReceipts: receipts,
            lastCaptureError: lastCaptureError,
            lastReplicationError: lastReplicationError,
            cycleRunning: cycleRunning,
            cycleCoalesced: cycleCoalesced,
            lastReplicationCycle: lastReplicationCycle,
            nextScheduledCycleAt: nextScheduledCycleAt,
            drainState: drainStateSymbol(drainSnapshot?.state),
            activeStages: drainSnapshot?.activeStages.map(\.rawValue) ?? [],
            lastDrainPass: drainPassSummary(drainSnapshot?.lastPass),
            nextWakeAt: drainSnapshot?.state == .waitingRetry
                ? drainSnapshot?.nextWakeAt.map(timestamp)
                : nil
        )
    }

    private static func drainStateSymbol(_ state: ArchiveV2DrainState?) -> String {
        guard let state, state != .stopped else { return ArchiveV2DrainState.idle.rawValue }
        return state.rawValue
    }

    private static func drainPassSummary(
        _ summary: ArchiveV2DrainPassSummary?
    ) -> EngramServiceArchiveV2DrainPassSummary? {
        guard let summary else { return nil }
        return try? EngramServiceArchiveV2DrainPassSummary(
            startedAt: timestamp(summary.startedAt),
            finishedAt: timestamp(summary.finishedAt),
            durationMs: max(summary.finishedAt.timeIntervalSince(summary.startedAt) * 1_000, 0),
            capturedFiles: summary.capturedFiles,
            capturedSourceBytes: summary.capturedSourceBytes,
            boundRows: summary.boundRows,
            policyRows: summary.policyRows,
            hqVerified: summary.hqVerified,
            m1Verified: summary.m1Verified,
            retryScheduled: summary.retryScheduled,
            quarantined: summary.quarantined,
            cancelled: false
        )
    }

    private static func remoteTelemetryResult(
        replicaID: String,
        backend: (any ArchiveReplicaBackend)?
    ) async -> (String, Result<ArchiveRemoteTelemetrySnapshot, any Error>)? {
        guard let backend else { return nil }
        do {
            return (replicaID, .success(try await backend.remoteTelemetryStatus()))
        } catch {
            return (replicaID, .failure(error))
        }
    }

    private static func replicationCycleSummary(
        result: ArchiveReplicationCycleResult,
        startedAt: Date,
        finishedAt: Date
    ) -> EngramServiceArchiveV2ReplicationCycleSummary? {
        try? EngramServiceArchiveV2ReplicationCycleSummary(
            startedAt: timestamp(startedAt),
            finishedAt: timestamp(finishedAt),
            durationMs: max(finishedAt.timeIntervalSince(startedAt) * 1_000, 0),
            claimedCount: result.claimed,
            verifiedCount: result.verified,
            retryScheduledCount: result.retryScheduled,
            quarantinedCount: result.quarantined,
            lostClaimCount: result.lostClaims,
            staleRecoveredCount: result.staleRecovered,
            reconciledCount: result.reconciled,
            cancelled: result.cancelled,
            cycleError: result.cycleError
        )
    }

    private static func replicaStatus(
        id: String,
        counts: ArchiveReplicaStatusCounts,
        remote: Result<ArchiveRemoteTelemetrySnapshot, any Error>?
    ) -> EngramServiceArchiveV2ReplicaStatus {
        let (queued, overflow) = counts.pending.addingReportingOverflow(counts.inflight)
        let retryReasons = counts.retryReasons.map {
            try! EngramServiceArchiveV2RetryReasonCount(
                symbol: $0.symbol,
                count: $0.count
            )
        }
        let remoteStatus: (EngramServiceArchiveV2RemoteTelemetry?, String?)
        switch remote {
        case .success(let snapshot) where snapshot.serverID == id:
            if let telemetry = remoteTelemetry(snapshot) {
                remoteStatus = (telemetry, nil)
            } else {
                remoteStatus = (nil, "invalid_canonical_response")
            }
        case .success:
            remoteStatus = (nil, "invalid_canonical_response")
        case .failure(let error):
            remoteStatus = (nil, remoteTelemetryErrorSymbol(error))
        case nil:
            remoteStatus = (nil, nil)
        }
        return try! EngramServiceArchiveV2ReplicaStatus(
            replicaID: id,
            queuedCount: overflow ? Int.max : queued,
            retryingCount: counts.retry,
            quarantinedCount: counts.quarantine,
            verifiedCount: counts.verified,
            oldestOutstandingAt: counts.oldestOutstandingAt,
            nextRetryAt: counts.nextRetryAt,
            retryReasons: retryReasons,
            remoteTelemetry: remoteStatus.0,
            remoteTelemetryError: remoteStatus.1
        )
    }

    private static func remoteTelemetry(
        _ snapshot: ArchiveRemoteTelemetrySnapshot
    ) -> EngramServiceArchiveV2RemoteTelemetry? {
        let endpoints = snapshot.endpoints.compactMap { endpoint in
            try? EngramServiceArchiveV2RemoteEndpoint(
                endpoint: endpoint.endpoint,
                requestCount: endpoint.requestCount,
                errorCount: endpoint.errorCount,
                totalDurationMs: endpoint.totalDurationMs,
                maximumDurationMs: endpoint.maximumDurationMs,
                requestBytes: endpoint.requestBytes,
                responseBytes: endpoint.responseBytes
            )
        }
        let recentErrors = snapshot.recentErrors.compactMap { error in
            try? EngramServiceArchiveV2RemoteError(
                timestamp: error.timestamp,
                endpoint: error.endpoint,
                method: error.method,
                statusCode: error.statusCode,
                category: error.category
            )
        }
        guard endpoints.count == snapshot.endpoints.count,
              recentErrors.count == snapshot.recentErrors.count else {
            return nil
        }
        return try? EngramServiceArchiveV2RemoteTelemetry(
            serverID: snapshot.serverID,
            sourceRevision: snapshot.sourceRevision,
            snapshotAt: snapshot.snapshotAt,
            uptimeSeconds: snapshot.uptimeSeconds,
            diskAvailableBytes: snapshot.diskAvailableBytes,
            diskTotalBytes: snapshot.diskTotalBytes,
            requestCount: snapshot.requestCount,
            clientErrorCount: snapshot.clientErrorCount,
            serverErrorCount: snapshot.serverErrorCount,
            lastArchiveMutationAt: snapshot.lastArchiveMutationAt,
            persistenceError: snapshot.persistenceError,
            endpoints: endpoints,
            recentErrors: recentErrors
        )
    }

    nonisolated static func remoteTelemetryErrorSymbol(_ error: Error) -> String {
        guard let backendError = error as? ArchiveReplicaBackendError else {
            return "remote_telemetry_unavailable"
        }
        return switch backendError {
        case .invalidDigest, .invalidRequest:
            "invalid_request"
        case .notHTTPResponse:
            "not_http_response"
        case .unexpectedStatus:
            "unexpected_status"
        case .responseTooLarge:
            "response_too_large"
        case .redirectRejected:
            "redirect_rejected"
        case .finalURLMismatch:
            "final_url_mismatch"
        case .invalidCanonicalResponse:
            "invalid_canonical_response"
        case .telemetryUnsupported:
            "telemetry_unsupported"
        case .transport(.cancelled):
            "transport_cancelled"
        case .transport(.timedOut):
            "transport_timeout"
        case .transport(.tls):
            "transport_tls"
        case .transport(.network):
            "transport_network"
        }
    }

    private static func retryResponse(
        accepted: Bool,
        resetRows: Int,
        error: String?
    ) -> EngramServiceArchiveV2RetryResponse {
        try! EngramServiceArchiveV2RetryResponse(
            accepted: accepted,
            resetRows: max(resetRows, 0),
            error: error
        )
    }
}
