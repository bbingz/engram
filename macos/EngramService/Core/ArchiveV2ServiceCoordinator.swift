import EngramCoreRead
import EngramCoreWrite
import Darwin
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
    let successfulTargets: [ArchiveV2ServiceCaptureTarget]
    let hasMore: Bool

    init(
        unsupported: Int,
        unsafe: Int,
        processed: Int = 0,
        capturedSourceBytes: Int64 = 0,
        transientRetryLocators: [SourceName: [String]] = [:],
        resolvedRetryLocators: [SourceName: [String]] = [:],
        successfulLocators: [SourceName: [String]] = [:],
        successfulTargets: [ArchiveV2ServiceCaptureTarget] = [],
        hasMore: Bool = false
    ) {
        self.unsupported = unsupported
        self.unsafe = unsafe
        self.processed = processed
        self.capturedSourceBytes = capturedSourceBytes
        self.transientRetryLocators = transientRetryLocators
        self.resolvedRetryLocators = resolvedRetryLocators
        self.successfulLocators = successfulLocators
        self.successfulTargets = successfulTargets
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
    let trustedTerminalFailuresByCaptureID: [String: ParserFailure]

    init(
        rows: [ArchiveV2ServiceSnapshotRow],
        trustedTerminalFailuresByCaptureID: [String: ParserFailure] = [:]
    ) {
        self.rows = rows
        self.trustedTerminalFailuresByCaptureID = trustedTerminalFailuresByCaptureID
    }
}

struct ArchiveV2ServiceUnknownPage: Equatable, Sendable {
    let targets: [ArchiveV2ServicePolicyTarget]
}

struct ArchiveV2ServiceRetryOutcome: Equatable, Sendable {
    let resetRows: Int
    let pauseRevisionByReplica: [String: UInt64]

    init(
        resetRows: Int,
        pauseRevisionByReplica: [String: UInt64] = [:]
    ) {
        self.resetRows = resetRows
        self.pauseRevisionByReplica = pauseRevisionByReplica.filter {
            ArchiveCatalog.currentReplicaIDs.contains($0.key)
        }
    }
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
        [any SessionAdapter],
        Bool,
        @escaping @Sendable () -> Bool
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
    var ignoreOne: @Sendable (ArchiveV2ServiceCaptureTarget) async throws -> Void
    var applyRemotePolicy: @Sendable (
        ArchiveV2ServicePolicyTarget,
        String?,
        ArchiveRemoteEligibility
    ) async throws -> Void
    var replicate: @Sendable (Int) async -> ArchiveReplicationCycleResult
    var replicateBacklog: @Sendable (
        Int,
        @escaping @Sendable () -> Bool
    ) async -> ArchiveReplicationCycleResult
    var status: @Sendable () async throws -> ArchiveStatusAggregate
    var remoteTelemetry: @Sendable () async -> RemoteTelemetryResults
    var retry: @Sendable (String?) async throws -> ArchiveV2ServiceRetryOutcome
    var recoveryDrill: @Sendable (String) async throws -> ArchiveRecoveryLease

    init(
        capture: @escaping @Sendable (
            [any SessionAdapter],
            Int,
            ArchiveCaptureCursorScope
        ) async throws -> ArchiveV2ServiceCaptureSummary,
        backlogCapture: (@Sendable (
            [any SessionAdapter],
            Bool,
            @escaping @Sendable () -> Bool
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
        ignoreOne: @escaping @Sendable (ArchiveV2ServiceCaptureTarget) async throws -> Void = { _ in },
        applyRemotePolicy: @escaping @Sendable (
            ArchiveV2ServicePolicyTarget,
            String?,
            ArchiveRemoteEligibility
        ) async throws -> Void,
        replicate: @escaping @Sendable (Int) async -> ArchiveReplicationCycleResult,
        replicateBacklog: (@Sendable (
            Int,
            @escaping @Sendable () -> Bool
        ) async -> ArchiveReplicationCycleResult)? = nil,
        status: @escaping @Sendable () async throws -> ArchiveStatusAggregate,
        remoteTelemetry: @escaping @Sendable () async -> RemoteTelemetryResults = { [:] },
        retry: @escaping @Sendable (
            String?
        ) async throws -> ArchiveV2ServiceRetryOutcome,
        recoveryDrill: @escaping @Sendable (String) async throws -> ArchiveRecoveryLease = { _ in
            throw ArchiveV2ServiceCoordinatorError.recoveryDrillUnavailable
        }
    ) {
        self.capture = capture
        self.backlogCapture = backlogCapture ?? { adapters, _, _ in
            try await capture(adapters, 32, .full)
        }
        self.bindingTargets = bindingTargets
        self.historicalUnknown = historicalUnknown
        self.advancePolicyCursor = advancePolicyCursor
        self.snapshot = snapshot
        self.bindOne = bindOne
        self.ignoreOne = ignoreOne
        self.applyRemotePolicy = applyRemotePolicy
        self.replicate = replicate
        self.replicateBacklog = replicateBacklog ?? { limit, _ in
            await replicate(limit)
        }
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

enum ArchiveV2BacklogPassPriority: String, Sendable {
    case remote
    case local

    var opposite: Self {
        switch self {
        case .remote: .local
        case .local: .remote
        }
    }
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

    private struct PendingIndexKey: Hashable, Sendable {
        let source: SourceName
        let locator: String
    }

    private struct BacklogIndexState: Sendable {
        let evaluatedLocators: [SourceName: [String]]
        let failedLocators: [SourceName: [String]]
        let recaptureLocators: [SourceName: [String]]
        let statesBySource: [SourceName: [String: FileIndexState]]
    }

    private struct ReplicaPauseState: Sendable {
        let reason: String
        let until: Date?
    }

    private static let backlogIndexLocatorLimit = 32
    private static let backlogIndexSourceByteLimit: Int64 = 128 * 1_024 * 1_024
    private static let backlogIndexRetryDelay: TimeInterval = 300

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
    private let drainConditions: @Sendable () -> ArchiveV2DrainConditions
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
    private var pendingIndexLocators: Set<PendingIndexKey> = []
    private var pendingIndexRetryAfter: [PendingIndexKey: Date] = [:]
    private var pendingIndexGeneration: [PendingIndexKey: ArchiveSourceGeneration] = [:]
    private var pendingIndexAwaitingCapture: Set<PendingIndexKey> = []
    private var fullCapturePending = true
    private var fullCaptureRefreshRequestID: UUID?
    private var lastReplicationCycle: EngramServiceArchiveV2ReplicationCycleSummary?
    private var nextBacklogPassPriority: ArchiveV2BacklogPassPriority = .remote
    private var replicaPauseStateByID: [String: ReplicaPauseState] = [:]
    private var replicaPauseRevisionByID: [String: UInt64] = [
        "hq": 0,
        "m1": 0,
    ]
    private var nextScheduledCycleAt: String?
    private var drainer: ArchiveV2BacklogDrainer?
    private var periodicMaintenanceActive = false
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
        now: @escaping @Sendable () -> Date = { Date() },
        drainConditions: @escaping @Sendable () -> ArchiveV2DrainConditions = {
            .current()
        }
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
        self.drainConditions = drainConditions
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
        now: @escaping @Sendable () -> Date = { Date() },
        drainConditions: @escaping @Sendable () -> ArchiveV2DrainConditions = {
            .current()
        }
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
        self.drainConditions = drainConditions
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

    func requestFullCaptureSweep() async {
        guard localCaptureReady else { return }
        fullCapturePending = true
        fullCaptureRefreshRequestID = UUID()
        await drainer?.signal()
    }

    func withBacklogDrainPaused<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        // Wait for any pass already inside the archive pipeline before starting
        // the higher-level periodic maintenance cycle.
        await acquirePipeline(indexPriority: true)
        periodicMaintenanceActive = true
        releasePipeline()

        do {
            let result = try await operation()
            periodicMaintenanceActive = false
            await drainer?.signal()
            return result
        } catch {
            periodicMaintenanceActive = false
            await drainer?.signal()
            throw error
        }
    }

    func runBacklogPass(
        adapters: [any SessionAdapter]
    ) async throws -> ArchiveV2DrainPassSummary {
        try await runBacklogPass(adapterProvider: { adapters })
    }

    func runBacklogPass(
        adapterProvider: @escaping @Sendable () -> [any SessionAdapter]
    ) async throws -> ArchiveV2DrainPassSummary {
        guard localCaptureReady, let operations else {
            return ArchiveV2DrainPassSummary(
                startedAt: now(),
                finishedAt: now()
            )
        }
        await acquirePipeline(indexPriority: false)
        defer { releasePipeline() }
        guard !periodicMaintenanceActive else {
            return ArchiveV2DrainPassSummary(
                startedAt: now(),
                finishedAt: now()
            )
        }
        let passPriority = nextBacklogPassPriority
        nextBacklogPassPriority = passPriority.opposite

        // Resolve profile-backed adapters only after this pass owns the archive
        // pipeline. A configuration request that arrived while waiting is then
        // represented by both the current adapter snapshot and its refresh ID.
        let adapters = adapterProvider()
        let consumedRefreshRequestID = fullCaptureRefreshRequestID
        let startedAt = now()
        let deadline = startedAt.addingTimeInterval(10)
        let shouldStartUnit: @Sendable () -> Bool = { [now, drainConditions] in
            !Task.isCancelled
                && now() < deadline
                && drainConditions().allowsNewWork
        }
        var capture = ArchiveV2ServiceCaptureSummary(unsupported: 0, unsafe: 0)
        var captureFailedThisPass = false
        var reconcile = ReconcileSummary(boundRows: 0, policyRows: 0, hasMore: false)
        var replication = ArchiveReplicationCycleResult()

        if passPriority == .remote {
            replication = try await runBacklogReplication(
                operations: operations,
                shouldStartUnit: shouldStartUnit
            )
        }

        if fullCapturePending, shouldStartUnit() {
            await drainer?.setActiveStages([.capture])
            do {
                capture = try await operations.backlogCapture(
                    adapters,
                    consumedRefreshRequestID != nil,
                    shouldStartUnit
                )
                unsupportedLocatorCount = max(capture.unsupported, 0)
                unsafeLocatorCount = max(capture.unsafe, 0)
                updateCaptureRetryLocators(with: capture)
                if fullCaptureRefreshRequestID == consumedRefreshRequestID {
                    fullCapturePending = capture.hasMore
                    fullCaptureRefreshRequestID = nil
                } else {
                    // A profile change arrived while this capture awaited I/O.
                    // Keep the newer refresh request armed for the next pass.
                    fullCapturePending = true
                }
                lastCaptureError = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                fullCapturePending = true
                captureFailedThisPass = true
                lastCaptureError = "capture_failure"
            }
        }

        // `file_index_state` is the durable retry authority. This actor-owned
        // set is only a bounded scheduling cache for the current full sweep;
        // after restart, the initial full capture sweep re-emits every durable
        // capture and rebuilds this cache from those persisted parse states.
        enqueuePendingIndexLocators(
            capture.successfulLocators,
            targets: capture.successfulTargets
        )
        let dueIndexLocators = duePendingIndexLocators(
            at: now(),
            locatorLimit: Self.backlogIndexLocatorLimit,
            sourceByteLimit: Self.backlogIndexSourceByteLimit
        )

        // A successful exact capture is not binding-ready until the matching
        // parser snapshot has been written. Admission uses the same deadline,
        // cancellation and power/thermal gate as every other drain unit.
        if !dueIndexLocators.isEmpty, shouldStartUnit() {
            await drainer?.setActiveStages([.indexing])
            do {
                let expectedGenerations = pendingIndexGeneration
                let indexed = try await writerGate.performWriteCommand(
                    name: "indexArchiveBacklog"
                ) { writer in
                    var evaluatedLocators: [SourceName: [String]] = [:]
                    var failedLocators: [SourceName: [String]] = [:]
                    var recaptureLocators: [SourceName: [String]] = [:]
                    var statesBySource: [SourceName: [String: FileIndexState]] = [:]
                    var stopAfterFailure = false
                    for source in dueIndexLocators.keys.sorted(
                        by: { $0.rawValue < $1.rawValue }
                    ) {
                        for locator in dueIndexLocators[source] ?? [] {
                            guard shouldStartUnit(), !stopAfterFailure else { break }
                            let pendingKey = PendingIndexKey(
                                source: source,
                                locator: locator
                            )
                            if let capturedGeneration = expectedGenerations[pendingKey],
                               Self.currentSourceGeneration(locator: locator)
                                != capturedGeneration {
                                recaptureLocators[source, default: []].append(locator)
                                continue
                            }
                            let singleLocator = [source: [locator]]
                            let parserAdapters = SessionAdapterFactory.indexingAdapters(
                                from: adapters,
                                capturedExactLocators: singleLocator
                            )
                            guard !parserAdapters.isEmpty else {
                                failedLocators[source, default: []].append(locator)
                                stopAfterFailure = true
                                break
                            }
                            do {
                                _ = try await writer.indexCapturedSessions(
                                    adapters: parserAdapters
                                )
                                evaluatedLocators[source, default: []].append(locator)
                                if let state = try writer.knownFileIndexStates(
                                    source: source,
                                    locators: [locator]
                                )[locator] {
                                    statesBySource[source, default: [:]][locator] = state
                                }
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                failedLocators[source, default: []].append(locator)
                                stopAfterFailure = true
                                break
                            }
                        }
                        if stopAfterFailure || !shouldStartUnit() {
                            break
                        }
                    }
                    return BacklogIndexState(
                        evaluatedLocators: evaluatedLocators,
                        failedLocators: failedLocators,
                        recaptureLocators: recaptureLocators,
                        statesBySource: statesBySource
                    )
                }.value
                for (source, locators) in indexed.recaptureLocators {
                    for locator in locators {
                        markPendingIndexAwaitingRecapture(
                            PendingIndexKey(source: source, locator: locator)
                        )
                    }
                }
                if !indexed.evaluatedLocators.isEmpty {
                    updatePendingIndexLocators(
                        indexed.evaluatedLocators,
                        statesBySource: indexed.statesBySource,
                        evaluatedAt: now()
                    )
                }
                if !indexed.failedLocators.isEmpty {
                    deferPendingIndexLocators(indexed.failedLocators, from: now())
                    lastCaptureError = "index_failure"
                } else if lastCaptureError == "index_failure" {
                    lastCaptureError = nil
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A top-level writer/index failure gets the same bounded retry
                // delay as a first parser failure. Per-locator parser failures
                // do not throw: their durable retry_after values are consumed
                // by updatePendingIndexLocators above.
                deferPendingIndexLocators(dueIndexLocators, from: now())
                lastCaptureError = "index_failure"
            }
        }

        if shouldStartUnit() {
            await drainer?.setActiveStages([.binding])
            reconcile = try await reconcileArchive(
                operations: operations,
                bindingLimit: 100,
                historicalLimit: 100,
                policyLimit: 100,
                reportDrainStages: true,
                shouldStartUnit: shouldStartUnit
            )
        }

        if passPriority == .local {
            replication = try await runBacklogReplication(
                operations: operations,
                shouldStartUnit: shouldStartUnit
            )
        }

        await drainer?.setActiveStages([])
        let aggregate = try await operations.status()
        let remoteRetryAt = Self.earliestRetryDate(
            aggregate,
            retryPausedUntilByReplica: replication.retryPausedUntilByReplica,
            attentionPausedReplicaIDs: Set(replication.pausedReplicaIDs)
        )
        let pendingIndex = pendingIndexSchedule(at: now())
        let nextRetryAt = [remoteRetryAt, pendingIndex.nextRetryAt]
            .compactMap { $0 }
            .min()
        let pausedReplicas = Set(
            replication.pausedReplicaIDs + replication.retryPausedReplicaIDs
        )
        let hasRunnableWork = capture.hasMore
            || (!captureFailedThisPass
                && fullCapturePending
                && !pendingIndexAwaitingCapture.isEmpty)
            || reconcile.hasMore
            || pendingIndex.hasDueWork
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

    private func runBacklogReplication(
        operations: ArchiveV2ServiceCoordinatorOperations,
        shouldStartUnit: @escaping @Sendable () -> Bool
    ) async throws -> ArchiveReplicationCycleResult {
        guard remoteReady, shouldStartUnit() else {
            return ArchiveReplicationCycleResult()
        }
        await drainer?.setActiveStages([.hq, .m1])
        let replicationStartedAt = now()
        let replication = await operations.replicateBacklog(
            16,
            shouldStartUnit
        )
        let replicationFinishedAt = now()
        lastReplicationCycle = Self.replicationCycleSummary(
            result: replication,
            startedAt: replicationStartedAt,
            finishedAt: replicationFinishedAt
        )
        lastReplicationError = replication.cycleError
        let effectiveReplication = updateReplicaPauseState(with: replication)
        if replication.cancelled { throw CancellationError() }
        return effectiveReplication
    }

    private func updateReplicaPauseState(
        with replication: ArchiveReplicationCycleResult
    ) -> ArchiveReplicationCycleResult {
        let attentionPausedReplicaIDs = Set(replication.pausedReplicaIDs)
        for replicaID in ArchiveCatalog.currentReplicaIDs {
            let currentRevision = replicaPauseRevisionByID[replicaID, default: 0]
            let incomingRevision = replication.pauseRevisionByReplica[replicaID] ?? 0
            guard incomingRevision >= currentRevision else { continue }

            replicaPauseRevisionByID[replicaID] = incomingRevision
            if attentionPausedReplicaIDs.contains(replicaID) {
                replicaPauseStateByID[replicaID] = ReplicaPauseState(
                    reason: "needsAttention",
                    until: nil
                )
            } else if let deadline = replication.retryPausedUntilByReplica[replicaID] {
                replicaPauseStateByID[replicaID] = ReplicaPauseState(
                    reason: "transientInfrastructureBackoff",
                    until: deadline
                )
            } else {
                replicaPauseStateByID.removeValue(forKey: replicaID)
            }
        }
        return replicationResult(
            replication,
            pauseStateByID: replicaPauseStateByID
        )
    }

    private func effectiveReplicaPauseState(at date: Date) -> [String: ReplicaPauseState] {
        replicaPauseStateByID.filter { _, state in
            state.until.map { $0 > date } ?? true
        }
    }

    private func replicationResult(
        _ result: ArchiveReplicationCycleResult,
        pauseStateByID: [String: ReplicaPauseState]
    ) -> ArchiveReplicationCycleResult {
        let attentionPausedReplicaIDs = pauseStateByID.compactMap { replicaID, state in
            state.reason == "needsAttention" ? replicaID : nil
        }
        let retryPausedUntilByReplica = pauseStateByID.reduce(
            into: [String: Date]()
        ) { deadlines, entry in
            if entry.value.reason == "transientInfrastructureBackoff",
               let deadline = entry.value.until {
                deadlines[entry.key] = deadline
            }
        }
        return ArchiveReplicationCycleResult(
            claimed: result.claimed,
            verified: result.verified,
            retryScheduled: result.retryScheduled,
            quarantined: result.quarantined,
            lostClaims: result.lostClaims,
            staleRecovered: result.staleRecovered,
            reconciled: result.reconciled,
            cancelled: result.cancelled,
            cycleError: result.cycleError,
            pausedReplicaIDs: attentionPausedReplicaIDs,
            retryPausedUntilByReplica: retryPausedUntilByReplica,
            pauseRevisionByReplica: replicaPauseRevisionByID,
            verifiedByReplica: result.verifiedByReplica
        )
    }

    private func enqueuePendingIndexLocators(
        _ locatorsBySource: [SourceName: [String]],
        targets: [ArchiveV2ServiceCaptureTarget]
    ) {
        for (source, locators) in locatorsBySource {
            for locator in locators {
                pendingIndexLocators.insert(
                    PendingIndexKey(source: source, locator: locator)
                )
            }
        }
        for target in targets {
            guard let generation = target.generation else { continue }
            let key = PendingIndexKey(
                source: target.source,
                locator: target.locator
            )
            let generationChanged = pendingIndexGeneration[key] != generation
            pendingIndexLocators.insert(key)
            pendingIndexGeneration[key] = generation
            pendingIndexAwaitingCapture.remove(key)
            if generationChanged {
                pendingIndexRetryAfter.removeValue(forKey: key)
            }
        }
    }

    private func duePendingIndexLocators(
        at date: Date,
        locatorLimit: Int,
        sourceByteLimit: Int64
    ) -> [SourceName: [String]] {
        guard locatorLimit > 0, sourceByteLimit > 0 else { return [:] }
        let candidates = pendingIndexLocators
            .filter { key in
                !pendingIndexAwaitingCapture.contains(key)
                    && (pendingIndexRetryAfter[key].map { $0 <= date } ?? true)
            }
            .sorted {
                ($0.source.rawValue, $0.locator) < ($1.source.rawValue, $1.locator)
            }
        var selected: [PendingIndexKey] = []
        var selectedBytes: Int64 = 0
        for key in candidates {
            guard selected.count < locatorLimit else { break }
            if let capturedGeneration = pendingIndexGeneration[key],
               Self.currentSourceGeneration(locator: key.locator)
                != capturedGeneration {
                markPendingIndexAwaitingRecapture(key)
                continue
            }
            let size = max(FileIndexStat.directFileStat(locator: key.locator)?.sizeBytes ?? 0, 0)
            let addition = selectedBytes.addingReportingOverflow(size)
            if !selected.isEmpty,
               (addition.overflow || addition.partialValue > sourceByteLimit) {
                continue
            }
            selected.append(key)
            selectedBytes = addition.overflow ? .max : addition.partialValue
        }
        return Dictionary(grouping: selected, by: \.source)
            .mapValues { $0.map(\.locator) }
    }

    private func updatePendingIndexLocators(
        _ evaluated: [SourceName: [String]],
        statesBySource: [SourceName: [String: FileIndexState]],
        evaluatedAt: Date
    ) {
        for (source, locators) in evaluated {
            for locator in locators {
                let key = PendingIndexKey(source: source, locator: locator)
                guard let stat = FileIndexStat.directFileStat(locator: locator) else {
                    pendingIndexLocators.remove(key)
                    pendingIndexRetryAfter.removeValue(forKey: key)
                    pendingIndexGeneration.removeValue(forKey: key)
                    pendingIndexAwaitingCapture.remove(key)
                    continue
                }
                if let capturedGeneration = pendingIndexGeneration[key],
                   Self.currentSourceGeneration(locator: locator)
                    != capturedGeneration {
                    markPendingIndexAwaitingRecapture(key)
                    continue
                }
                guard let state = statesBySource[source]?[locator],
                      state.schemaVersion == FileIndexState.currentSchemaVersion,
                      state.sameFileIdentity(as: stat) else {
                    pendingIndexRetryAfter[key] = evaluatedAt.addingTimeInterval(
                        Self.backlogIndexRetryDelay
                    )
                    continue
                }
                switch state.parseStatus {
                case .ok, .terminal:
                    pendingIndexLocators.remove(key)
                    pendingIndexRetryAfter.removeValue(forKey: key)
                    pendingIndexGeneration.removeValue(forKey: key)
                    pendingIndexAwaitingCapture.remove(key)
                case .retry:
                    let retryAt = state.retryAfterEpochSeconds.map {
                        Date(timeIntervalSince1970: TimeInterval($0))
                    } ?? evaluatedAt.addingTimeInterval(Self.backlogIndexRetryDelay)
                    pendingIndexRetryAfter[key] = max(retryAt, evaluatedAt)
                }
            }
        }
    }

    private func deferPendingIndexLocators(
        _ locatorsBySource: [SourceName: [String]],
        from date: Date
    ) {
        let retryAt = date.addingTimeInterval(Self.backlogIndexRetryDelay)
        for (source, locators) in locatorsBySource {
            for locator in locators {
                pendingIndexRetryAfter[
                    PendingIndexKey(source: source, locator: locator)
                ] = retryAt
            }
        }
    }

    private func pendingIndexSchedule(
        at date: Date
    ) -> (hasDueWork: Bool, nextRetryAt: Date?) {
        var hasDueWork = false
        var nextRetryAt: Date?
        for key in pendingIndexLocators {
            if pendingIndexAwaitingCapture.contains(key) {
                continue
            }
            guard let retryAt = pendingIndexRetryAfter[key] else {
                hasDueWork = true
                continue
            }
            if retryAt <= date {
                hasDueWork = true
            } else if nextRetryAt == nil || retryAt < nextRetryAt! {
                nextRetryAt = retryAt
            }
        }
        return (hasDueWork, nextRetryAt)
    }

    private func markPendingIndexAwaitingRecapture(_ key: PendingIndexKey) {
        pendingIndexAwaitingCapture.insert(key)
        pendingIndexRetryAfter.removeValue(forKey: key)
        fullCapturePending = true
        if fullCaptureRefreshRequestID == nil {
            fullCaptureRefreshRequestID = UUID()
        }
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
        let effectiveReplicaPauseStateByID: [String: ReplicaPauseState]
        if replicaPauseStateByID.values.contains(where: { $0.until != nil }) {
            effectiveReplicaPauseStateByID = effectiveReplicaPauseState(at: now())
        } else {
            effectiveReplicaPauseStateByID = replicaPauseStateByID
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
            nextPassPriority: nextBacklogPassPriority,
            replicaPauseStateByID: effectiveReplicaPauseStateByID,
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
            let outcome = try await operations.retry(replicaID)
            applyRetryOutcome(outcome, replicaID: replicaID)
            await drainer?.signal()
            return Self.retryResponse(
                accepted: true,
                resetRows: outcome.resetRows,
                error: nil
            )
        } catch is CancellationError {
            return Self.retryResponse(accepted: false, resetRows: 0, error: "cancelled")
        } catch {
            return Self.retryResponse(accepted: false, resetRows: 0, error: "catalog_failure")
        }
    }

    private func applyRetryOutcome(
        _ outcome: ArchiveV2ServiceRetryOutcome,
        replicaID: String?
    ) {
        let replicaIDs = replicaID.map { [$0] } ?? ArchiveCatalog.currentReplicaIDs
        for replicaID in replicaIDs {
            let currentRevision = replicaPauseRevisionByID[replicaID, default: 0]
            if let incomingRevision = outcome.pauseRevisionByReplica[replicaID] {
                guard incomingRevision >= currentRevision else { continue }
                replicaPauseRevisionByID[replicaID] = incomingRevision
            } else {
                replicaPauseRevisionByID[replicaID] = currentRevision == .max
                    ? .max
                    : currentRevision + 1
            }
            replicaPauseStateByID.removeValue(forKey: replicaID)
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
                    || fullCaptureRefreshRequestID != nil
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
        reportDrainStages: Bool = false,
        shouldStartUnit: @escaping @Sendable () -> Bool = { true }
    ) async throws -> ReconcileSummary {
        guard shouldStartUnit() else {
            return ReconcileSummary(boundRows: 0, policyRows: 0, hasMore: true)
        }
        let bindingTargets = try await operations.bindingTargets(bindingLimit)
        let historicalPage = policySnapshotReady && shouldStartUnit()
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
        guard shouldStartUnit() else {
            return ReconcileSummary(boundRows: 0, policyRows: 0, hasMore: true)
        }
        let snapshot = try await operations.snapshot(writerGate, snapshotTargets)
        try Task.checkCancellation()

        var newlyBound: [ArchiveV2ServicePolicyTarget] = []
        var deferredWork = false
        for target in bindingTargets.prefix(bindingLimit) {
            try Task.checkCancellation()
            guard shouldStartUnit() else {
                deferredWork = true
                break
            }
            if snapshot.trustedTerminalFailuresByCaptureID[target.captureID]
                == .noVisibleMessages {
                try await operations.ignoreOne(target)
                continue
            }
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
                guard shouldStartUnit() else {
                    deferredWork = true
                    break
                }
                try await applyPolicy(target, snapshot: snapshot, operations: operations)
                try await operations.advancePolicyCursor(target)
                remainingPolicyBudget -= 1
                appliedPolicy += 1
            }
            for target in newlyBound.prefix(remainingPolicyBudget) {
                try Task.checkCancellation()
                guard shouldStartUnit() else {
                    deferredWork = true
                    break
                }
                try await applyPolicy(target, snapshot: snapshot, operations: operations)
                appliedPolicy += 1
            }
        }
        return ReconcileSummary(
            boundRows: newlyBound.count,
            policyRows: appliedPolicy,
            hasMore: deferredWork
                || (bindingLimit > 0 && bindingTargets.count >= bindingLimit)
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
            backlogCapture: { adapters, refreshLocatorSnapshot, shouldStartUnit in
                let result = try await captureCoordinator.capture(
                    adapters: adapters,
                    budget: ArchiveCaptureBudget(
                        locatorLimit: 32,
                        sourceByteLimit: 128 * 1_024 * 1_024
                    ),
                    cursorScope: .full,
                    refreshLocatorSnapshot: refreshLocatorSnapshot,
                    restartLocatorSweep: refreshLocatorSnapshot,
                    shouldStartUnit: shouldStartUnit
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
            ignoreOne: { target in
                _ = try await captureCoordinator.ignoreLockedBindingTarget(
                    captureID: target.captureID,
                    reason: "no_visible_messages",
                    updatedAt: Self.timestamp(Date())
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
            replicateBacklog: { limit, shouldStartUnit in
                guard let replicationCoordinator else {
                    return ArchiveReplicationCycleResult()
                }
                return await replicationCoordinator.runBacklogPass(
                    perReplicaLimit: limit,
                    shouldStartUnit: shouldStartUnit
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
                let revisions = await replicationCoordinator?.resumeAfterAttention(
                    replicaID: replicaID
                ) ?? [:]
                return ArchiveV2ServiceRetryOutcome(
                    resetRows: count,
                    pauseRevisionByReplica: revisions
                )
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
            successfulTargets: result.captures.compactMap {
                Self.captureTarget($0.capture)
            },
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
        var trustedTerminalFailuresByCaptureID: [String: ParserFailure] = [:]
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
                    let indexStateMatchesFreshStat = state?.schemaVersion
                        == FileIndexState.currentSchemaVersion
                        && state?.inode != nil
                        && state?.device != nil
                        && freshStat.map { state?.sameFileIdentity(as: $0) == true } == true
                    let trusted = indexStateMatchesFreshStat
                        && state?.parseStatus == .ok
                        && captureMatchesFreshStat
                    if indexStateMatchesFreshStat,
                       captureMatchesFreshStat,
                       state?.parseStatus == .terminal,
                       state?.failureKind == .noVisibleMessages {
                        trustedTerminalFailuresByCaptureID[target.captureID] = .noVisibleMessages
                    }
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
        return ArchiveV2ServiceIndexSnapshot(
            rows: result,
            trustedTerminalFailuresByCaptureID: trustedTerminalFailuresByCaptureID
        )
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
        var retryAfter: String?
    }

    private struct LegacyPolicyCursorPayload: Codable, Equatable {
        let schemaVersion: Int
        var boundary: PersistedPolicyCursor?
        var after: PersistedPolicyCursor?
    }

    static let historicalPolicyRetryInterval: TimeInterval = 86_400

    static func loadHistoricalUnknownPage(
        catalog: ArchiveCatalog,
        limit: Int,
        now: () -> Date = { Date() }
    ) throws -> ArchiveV2ServiceUnknownPage {
        guard limit > 0 else {
            throw ArchiveCatalogError.invalidLimit(limit)
        }
        var progress = try loadPolicyProgress(catalog: catalog)
        let instant = now()
        if let retryAfter = progress.retryAfter,
           let retryDate = policyTimestampDate(retryAfter),
           instant < retryDate {
            return ArchiveV2ServiceUnknownPage(targets: [])
        }
        if progress.boundary == nil {
            progress.boundary = try catalog.unknownBindingBoundary().map(
                PersistedPolicyCursor.init
            )
            progress.after = nil
            progress.retryAfter = nil
            if progress.boundary == nil {
                progress.retryAfter = timestamp(
                    instant.addingTimeInterval(historicalPolicyRetryInterval)
                )
            }
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
            // A historical row that remains unknown usually lacks a trusted
            // index match. Reopening the sweep on every maintenance signal just
            // replays the same SQLite reads, so persist a daily retry boundary.
            // Newly bound rows still take the direct policy path immediately.
            try storePolicyProgress(
                catalog: catalog,
                progress: PolicyCursorPayload(
                    schemaVersion: 3,
                    boundary: nil,
                    after: nil,
                    retryAfter: timestamp(
                        instant.addingTimeInterval(historicalPolicyRetryInterval)
                    )
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
                schemaVersion: 3,
                boundary: nil,
                after: nil,
                retryAfter: nil
            )
        }
        let schema = try JSONSerialization.jsonObject(with: checkpoint.payload)
        guard let schemaVersion = (schema as? [String: Any])?["schemaVersion"] as? Int else {
            throw ArchiveCatalogError.invalidArchiveCursorCheckpoint(
                ArchiveCursorKey.policyCycle.rawValue
            )
        }
        let payload: PolicyCursorPayload
        if schemaVersion == 2 {
            let legacy = try ArchiveCanonicalJSON.decode(
                LegacyPolicyCursorPayload.self,
                from: checkpoint.payload
            )
            guard try ArchiveCanonicalJSON.encode(legacy) == checkpoint.payload else {
                throw ArchiveCatalogError.invalidArchiveCursorCheckpoint(
                    ArchiveCursorKey.policyCycle.rawValue
                )
            }
            payload = PolicyCursorPayload(
                schemaVersion: 3,
                boundary: legacy.boundary,
                after: legacy.after,
                retryAfter: nil
            )
        } else {
            payload = try ArchiveCanonicalJSON.decode(
                PolicyCursorPayload.self,
                from: checkpoint.payload
            )
        }
        let isCanonicalPayload: Bool
        if schemaVersion == 2 {
            isCanonicalPayload = true
        } else {
            isCanonicalPayload = try ArchiveCanonicalJSON.encode(payload) == checkpoint.payload
        }
        guard payload.schemaVersion == 3,
              payload.boundary != nil || payload.after == nil,
              validPolicyCursor(payload.boundary),
              validPolicyCursor(payload.after),
              validPolicyTimestamp(payload.retryAfter),
              isCanonicalPayload else {
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

    private static func policyTimestampDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard formatter.date(from: value).map(formatter.string(from:)) == value else {
            return nil
        }
        return formatter.date(from: value)
    }

    private static func validPolicyTimestamp(_ value: String?) -> Bool {
        guard let value else { return true }
        return policyTimestampDate(value) != nil
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

    static func currentSourceGeneration(
        locator: String
    ) -> ArchiveSourceGeneration? {
        var info = stat()
        guard Darwin.lstat(locator, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        let mtimeSeconds = Int64(info.st_mtimespec.tv_sec)
        let mtimeNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        let ctimeSeconds = Int64(info.st_ctimespec.tv_sec)
        let ctimeNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        guard mtimeSeconds >= 0,
              ctimeSeconds >= 0,
              mtimeNanoseconds >= 0,
              mtimeNanoseconds < 1_000_000_000,
              ctimeNanoseconds >= 0,
              ctimeNanoseconds < 1_000_000_000 else {
            return nil
        }
        let mtime = mtimeSeconds.multipliedReportingOverflow(by: 1_000_000_000)
        let ctime = ctimeSeconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !mtime.overflow, !ctime.overflow else { return nil }
        let mtimeNs = mtime.partialValue.addingReportingOverflow(mtimeNanoseconds)
        let ctimeNs = ctime.partialValue.addingReportingOverflow(ctimeNanoseconds)
        guard !mtimeNs.overflow, !ctimeNs.overflow else { return nil }
        return try? ArchiveSourceGeneration(
            device: Int64(info.st_dev),
            inode: Int64(info.st_ino),
            size: Int64(info.st_size),
            mtimeNs: mtimeNs.partialValue,
            ctimeNs: ctimeNs.partialValue,
            mode: Int64(info.st_mode)
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

    private static func earliestRetryDate(
        _ aggregate: ArchiveStatusAggregate,
        retryPausedUntilByReplica: [String: Date] = [:],
        attentionPausedReplicaIDs: Set<String> = []
    ) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let retryDates = [
            "hq": aggregate.hq.nextRetryAt.flatMap(formatter.date(from:)),
            "m1": aggregate.m1.nextRetryAt.flatMap(formatter.date(from:)),
        ]
        let pendingCounts = [
            "hq": aggregate.hq.pending,
            "m1": aggregate.m1.pending,
        ]
        return ArchiveCatalog.currentReplicaIDs.compactMap { replicaID in
            guard !attentionPausedReplicaIDs.contains(replicaID) else {
                return nil
            }
            let catalogDate = retryDates[replicaID] ?? nil
            guard let pauseDeadline = retryPausedUntilByReplica[replicaID] else {
                return catalogDate
            }
            if pendingCounts[replicaID, default: 0] > 0 {
                return pauseDeadline
            }
            return max(catalogDate ?? .distantPast, pauseDeadline)
        }.min()
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
        nextPassPriority: ArchiveV2BacklogPassPriority,
        replicaPauseStateByID: [String: ReplicaPauseState],
        drainSnapshot: ArchiveV2DrainSnapshot?
    ) -> EngramServiceArchiveV2StatusResponse {
        let replicas = [
            replicaStatus(
                id: "hq",
                counts: aggregate.hq,
                pauseState: replicaPauseStateByID["hq"],
                remote: remoteTelemetry["hq"]
            ),
            replicaStatus(
                id: "m1",
                counts: aggregate.m1,
                pauseState: replicaPauseStateByID["m1"],
                remote: remoteTelemetry["m1"]
            ),
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
            ignoredEmptyCaptureCount: aggregate.ignoredEmpty,
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
            nextPassPriority: nextPassPriority.rawValue,
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
        pauseState: ReplicaPauseState?,
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
            pauseReason: pauseState?.reason,
            pausedUntil: pauseState?.until.map(timestamp),
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
