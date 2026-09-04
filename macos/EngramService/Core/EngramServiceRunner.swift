import Darwin
import Foundation
import GRDB
import EngramCoreRead
import EngramCoreWrite

func engramServiceAbsoluteArgumentValue(after flag: String, in arguments: [String]) throws -> String? {
    guard let index = arguments.firstIndex(of: flag) else {
        return nil
    }
    let valueIndex = arguments.index(after: index)
    guard arguments.indices.contains(valueIndex),
          let value = UnixSocketEngramServiceTransport.normalizedAbsolutePath(arguments[valueIndex]) else {
        throw EngramServiceError.invalidRequest(message: "\(flag) requires a non-empty absolute path")
    }
    return value
}

final class EmbeddingMaintenanceBackoff: @unchecked Sendable {
    static let shared = EmbeddingMaintenanceBackoff()

    private struct ProviderState {
        var consecutiveFailures: Int
        var retryAfter: Date
    }

    private let baseDelay: TimeInterval
    private let maximumDelay: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var providers: [String: ProviderState] = [:]

    init(
        baseDelay: TimeInterval = 3_600,
        maximumDelay: TimeInterval = 86_400,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseDelay = max(baseDelay, 1)
        self.maximumDelay = max(maximumDelay, self.baseDelay)
        self.now = now
    }

    func shouldAttempt(providerKey: String) -> Bool {
        lock.withLock {
            guard let state = providers[providerKey] else { return true }
            return now() >= state.retryAfter
        }
    }

    @discardableResult
    func recordFailure(providerKey: String) -> TimeInterval {
        lock.withLock {
            let failureCount = (providers[providerKey]?.consecutiveFailures ?? 0) + 1
            let exponent = min(max(failureCount - 1, 0), 20)
            let delay = min(maximumDelay, baseDelay * pow(2, Double(exponent)))
            providers[providerKey] = ProviderState(
                consecutiveFailures: failureCount,
                retryAfter: now().addingTimeInterval(delay)
            )
            return delay
        }
    }

    func recordSuccess(providerKey: String) {
        lock.withLock {
            _ = providers.removeValue(forKey: providerKey)
        }
    }

    func remainingDelay(providerKey: String) -> TimeInterval {
        lock.withLock {
            guard let state = providers[providerKey] else { return 0 }
            return max(0, state.retryAfter.timeIntervalSince(now()))
        }
    }
}

final class RepoDiscoveryMaintenanceThrottle: @unchecked Sendable {
    static let shared = RepoDiscoveryMaintenanceThrottle()

    private let batchLimit: Int
    private let cooldown: TimeInterval
    private let failureCooldown: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var retryAfterByCwd: [String: Date] = [:]

    init(
        batchLimit: Int = 32,
        cooldown: TimeInterval = 21_600,
        failureCooldown: TimeInterval = 900,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.batchLimit = max(batchLimit, 1)
        self.cooldown = max(cooldown, 1)
        self.failureCooldown = max(failureCooldown, 0)
        self.now = now
    }

    /// F3: selection is not an attempt. Cooldown is recorded only after
    /// `recordOutcomes`, so a failed git probe cannot burn the success window.
    func selectCandidates(
        _ candidates: [GitRepoCandidate],
        forcedCwds: Set<String> = []
    ) -> [GitRepoCandidate] {
        lock.withLock {
            let instant = now()
            if retryAfterByCwd.count > candidates.count * 2 {
                let activeCwds = Set(candidates.map(\.cwd))
                retryAfterByCwd = retryAfterByCwd.filter { activeCwds.contains($0.key) }
            }
            let forced = candidates.filter { forcedCwds.contains($0.cwd) }
            let cooled = candidates.lazy.filter { candidate in
                guard !forcedCwds.contains(candidate.cwd) else { return false }
                guard let retryAfter = self.retryAfterByCwd[candidate.cwd] else { return true }
                return instant >= retryAfter
            }
            return Array((forced + Array(cooled)).prefix(batchLimit))
        }
    }

    func recordOutcomes(succeeded: [String], failed: [String]) {
        lock.withLock {
            let instant = now()
            let successRetry = instant.addingTimeInterval(cooldown)
            for cwd in succeeded where !cwd.isEmpty {
                retryAfterByCwd[cwd] = successRetry
            }
            if failureCooldown > 0 {
                let failureRetry = instant.addingTimeInterval(failureCooldown)
                for cwd in failed where !cwd.isEmpty {
                    retryAfterByCwd[cwd] = failureRetry
                }
            }
        }
    }
}

actor LiveIngestPublishSignal {
    enum Wake: Equatable, Sendable {
        case timer(changeGeneration: Int)
        case indexChanged(changeGeneration: Int)

        var changeGeneration: Int {
            switch self {
            case .timer(let generation), .indexChanged(let generation):
                generation
            }
        }
    }

    private var signaledGeneration = 0
    private var publishedGeneration = 0
    private var pendingDeltaToken: OffloadRepo.LivePublishDeltaToken?
    private var pendingDeltaGeneration: Int?
    private var sleeperTask: Task<Void, Error>?
    private var wakeOnIndexChange = false

    /// Identical actual-delta identities coalesce, while every distinct ready
    /// snapshot/retraction set gets its own trailing-debounce generation.
    func signalIndexChange(token: OffloadRepo.LivePublishDeltaToken) {
        if pendingDeltaToken == token,
           let pendingDeltaGeneration,
           pendingDeltaGeneration > publishedGeneration {
            return
        }
        signaledGeneration += 1
        pendingDeltaToken = token
        pendingDeltaGeneration = signaledGeneration
        if wakeOnIndexChange {
            sleeperTask?.cancel()
        }
    }

    func wait(
        intervalNanoseconds: UInt64,
        debounceNanoseconds: UInt64,
        respondsToIndexChanges: Bool,
        sleep: @escaping @Sendable (UInt64) async throws -> Void
    ) async throws -> Wake {
        if respondsToIndexChanges, signaledGeneration > publishedGeneration {
            return .indexChanged(
                changeGeneration: try await waitForDebounce(
                    nanoseconds: debounceNanoseconds,
                    sleep: sleep
                )
            )
        }

        let timerGeneration = signaledGeneration
        do {
            try await sleepOnce(
                nanoseconds: intervalNanoseconds,
                wakeOnIndexChange: respondsToIndexChanges,
                sleep: sleep
            )
            if respondsToIndexChanges, signaledGeneration > timerGeneration {
                return .indexChanged(
                    changeGeneration: try await waitForDebounce(
                        nanoseconds: debounceNanoseconds,
                        sleep: sleep
                    )
                )
            }
            return .timer(changeGeneration: timerGeneration)
        } catch is CancellationError {
            if Task.isCancelled { throw CancellationError() }
            guard respondsToIndexChanges, signaledGeneration > publishedGeneration else {
                throw CancellationError()
            }
            return .indexChanged(
                changeGeneration: try await waitForDebounce(
                    nanoseconds: debounceNanoseconds,
                    sleep: sleep
                )
            )
        }
    }

    func markPublished(through changeGeneration: Int) {
        publishedGeneration = max(publishedGeneration, changeGeneration)
        if let pendingDeltaGeneration,
           pendingDeltaGeneration <= publishedGeneration {
            pendingDeltaToken = nil
            self.pendingDeltaGeneration = nil
        }
    }

    private func waitForDebounce(
        nanoseconds: UInt64,
        sleep: @escaping @Sendable (UInt64) async throws -> Void
    ) async throws -> Int {
        while true {
            let generation = signaledGeneration
            do {
                try await sleepOnce(
                    nanoseconds: nanoseconds,
                    wakeOnIndexChange: true,
                    sleep: sleep
                )
                if generation == signaledGeneration {
                    return generation
                }
            } catch is CancellationError {
                if Task.isCancelled { throw CancellationError() }
                guard signaledGeneration > generation else { throw CancellationError() }
            }
        }
    }

    private func sleepOnce(
        nanoseconds: UInt64,
        wakeOnIndexChange: Bool,
        sleep: @escaping @Sendable (UInt64) async throws -> Void
    ) async throws {
        let task = Task { try await sleep(nanoseconds) }
        sleeperTask = task
        self.wakeOnIndexChange = wakeOnIndexChange
        defer {
            sleeperTask = nil
            self.wakeOnIndexChange = false
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

public enum EngramServiceRunner {
    public static func run(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        let runtimeHome = RemoteSyncConfig.homeDirectory(environment: environment)
        let isTestProcess = environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let serviceHome = isTestProcess
            ? runtimeHome
            : FileManager.default.homeDirectoryForCurrentUser
        let implicitSocketPath = UnixSocketEngramServiceTransport.defaultSocketPath(
            homeDirectory: serviceHome
        )
        var configuredSocketPath: String?
        for key in ["ENGRAM_MCP_SERVICE_SOCKET", "ENGRAM_SERVICE_SOCKET"] {
            guard let rawValue = environment[key] else { continue }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard let normalized = UnixSocketEngramServiceTransport.normalizedAbsolutePath(
                value,
                homeDirectory: serviceHome
            ) else {
                throw EngramServiceError.invalidRequest(message: "\(key) requires a non-empty absolute path")
            }
            configuredSocketPath = normalized
            break
        }
        let socketPath = try engramServiceAbsoluteArgumentValue(after: "--service-socket", in: arguments)
            ?? configuredSocketPath
            ?? implicitSocketPath
        // docs/invariants.md #6: the service database follows the same hermetic runtime home.
        let databasePath = try engramServiceAbsoluteArgumentValue(after: "--database-path", in: arguments)
            ?? serviceHome
                .appendingPathComponent(".engram", isDirectory: true)
                .appendingPathComponent("index.sqlite")
                .path
        let settingsURL = engramSettingsURL(environment: environment)

        let runtimeDirectory: URL
        let usesDedicatedRuntime = socketPath == implicitSocketPath
        if usesDedicatedRuntime {
            // docs/invariants.md #6: XCTest uses its injected fixed home and
            // never creates or repairs the process user's ~/.engram/run.
            runtimeDirectory = try UnixSocketEngramServiceTransport.secureRuntimeDirectory(
                homeDirectory: serviceHome
            )
            // SEC-L3: repair cache/exports/probes (and peers) that may still be 0755.
            EngramUserDataDirectory.secureExistingProductSubdirectories(homeDirectory: serviceHome)
        } else {
            let socketURL = URL(fileURLWithPath: socketPath)
            runtimeDirectory = try UnixSocketEngramServiceTransport.secureRuntimeDirectory(
                at: socketURL.deletingLastPathComponent()
            )
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: databasePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try removeLegacyWebUIToken(runtimeDirectory: runtimeDirectory, homeDirectory: serviceHome)
        } catch {
            ServiceLogger.warn("failed to remove legacy web UI token: \(error.localizedDescription)", category: .runner)
        }

        let socketBasename = URL(fileURLWithPath: socketPath).lastPathComponent
        let databaseBasename = URL(fileURLWithPath: databasePath).lastPathComponent

        ServiceLogger.info(
            "starting service: socket=\(socketBasename) database=\(databaseBasename)",
            category: .runner
        )

        let gate = try ServiceWriterGate(
            databasePath: databasePath,
            runtimeDirectory: runtimeDirectory,
            // Custom socket parents are caller-owned. The database-adjacent
            // lock still enforces invariant 1 without writing a generic lock
            // file into that directory.
            acquireRuntimeLock: usesDedicatedRuntime
        )

        // Composition root: run migrations ONCE before serving (idempotent), and
        // fail fast if the schema is still absent afterward. A missing `sessions`
        // table means migrations did not actually create the schema, which would
        // otherwise surface as silent total:0 / empty results downstream.
        do {
            _ = try await gate.performWriteCommand(name: "migrate") { writer in
                try writer.migrate()
                try writer.verifySchemaPresent() // throws .missingSchema if schema absent
                // Invariants 1 and 14: repair insight lifecycle chains through
                // the service writer before any agent-facing listener starts.
                _ = try writer.write { db in
                    try StartupBackfills.reconcileInsights(db)
                }
                // R1/R2 P1 settings-db-split: finish any source visibility
                // intent left durable by a process exit between the settings
                // rename and SQLite commit before the service starts serving.
                try EngramServiceCommandHandler.reconcilePendingSourceVisibilityIntent(
                    writer: writer,
                    settingsURL: settingsURL
                )
            }
            ServiceLogger.notice("schema migration complete", category: .runner)
        } catch {
            ServiceLogger.error("fatal: schema migration failed", category: .runner, error: error)
            emit(ServiceFatalEvent(stage: "migrate", error: error.localizedDescription))
            exit(70) // EX_SOFTWARE
        }

        // Archive V2 has one process-wide coordinator. Its default-off factory
        // only reads settings and returns a dormant actor: it does not create
        // archive storage, read Keychain credentials, or construct backends.
        let archiveV2Settings = ArchiveV2Settings.load(
            settingsURL: settingsURL,
            environment: environment
        )
        let archiveV2Coordinator = Self.makeArchiveV2Coordinator(
            gate: gate,
            databasePath: databasePath,
            settings: archiveV2Settings,
            settingsURL: settingsURL,
            environment: environment
        )
        let archiveV2Drainer: ArchiveV2BacklogDrainer?
        if archiveV2Settings.exactArchiveEnabled {
            // Reread disabled sources inside every backlog pass. Capturing a
            // startup snapshot would keep draining a source after the user
            // disables it (and miss a source re-enabled while the service lives).
            let drainer = ArchiveV2BacklogDrainer { [weak archiveV2Coordinator] in
                guard let archiveV2Coordinator else {
                    throw CancellationError()
                }
                return try await archiveV2Coordinator.runBacklogPass(
                    adapterProvider: {
                        Self.exactArchiveAdaptersForBacklogPass(environment: environment)
                    },
                    excludedSnapshotSourcesProvider: {
                        Set(
                            Self.readDisabledSources(environment: environment)
                                .compactMap(SourceName.init(rawValue:))
                        )
                    }
                )
            }
            await archiveV2Coordinator.attachDrainer(drainer)
            archiveV2Drainer = drainer
        } else {
            archiveV2Drainer = nil
        }
        let archiveTranscriptResolver = archiveV2Coordinator.transcriptResolverSnapshot
        let profileArchiveCatalog: ArchiveCatalog?
        if archiveV2Settings.exactArchiveEnabled {
            let archiveRoot = URL(fileURLWithPath: databasePath)
                .deletingLastPathComponent()
                .appendingPathComponent("archive-v2", isDirectory: true)
            profileArchiveCatalog = try? ArchiveCatalog(root: archiveRoot)
        } else {
            profileArchiveCatalog = nil
        }
        let claudeCodeProfileService = ClaudeCodeProfileService(
            profileResolver: ClaudeCodeProfileResolver(
                homeDirectory: serviceHome,
                settingsURL: settingsURL
            ),
            writerGate: gate,
            archiveCatalog: profileArchiveCatalog,
            settingsURL: settingsURL,
            signalDrainer: {
                await archiveV2Coordinator.requestFullCaptureSweep()
            }
        )

        let statusMonitor = ServiceStatusMonitor()
        // Wire breaker transition logs once at process start (os_log subsystem
        // com.engram.service, category ai). Counters stay on the shared breaker
        // and surface through ServiceTelemetryCollector.snapshot().
        EmbeddingGuardrails.sharedBreaker.setOnTransition { providerKey, transition in
            ServiceLogger.info(
                "embedding circuit \(transition.rawValue) provider=\(providerKey)",
                category: .ai
            )
        }
        let telemetry = ServiceTelemetryCollector(embeddingBreaker: EmbeddingGuardrails.sharedBreaker)
        // Sanitized in-process log ring: tee a redacted copy of each service log
        // line so the gated Observability "Logs" tab is readable (os_log stays
        // `privacy: .private`). Install BEFORE the server starts so startup lines
        // are captured.
        let logRing = ServiceLogRing()
        ServiceLogger.installRing(logRing)
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            archiveV2Coordinator: archiveV2Coordinator,
            archiveTranscriptResolver: archiveTranscriptResolver,
            claudeCodeProfileService: claudeCodeProfileService,
            readProvider: try SQLiteEngramServiceReadProvider(databasePath: databasePath),
            statusMonitor: statusMonitor,
            telemetry: telemetry,
            logRing: logRing
        )
        let server = UnixSocketServiceServer(
            socketPath: socketPath,
            onShutdown: { _ = kill(getpid(), SIGTERM) }
        ) { request in
            await handler.handle(request)
        }
        try server.start()

        ServiceLogger.notice("service ready, listening on \(socketBasename)", category: .runner)
        emit(ServiceReadyEvent(socket: socketPath))
        await statusMonitor.recordServiceReady()
        // Publish initial S01 schedule before the first sleep so status/telemetry
        // smoke never sees a fixed 5-minute interval (min is 15m).
        let initialInterval = Int(IndexingSchedulePolicy.minInterval)
        await statusMonitor.recordSchedule(nextScanIntervalSeconds: initialInterval)
        await telemetry.recordSchedule(
            nextScanIntervalSeconds: initialInterval,
            targetIntervalSeconds: initialInterval,
            consecutiveIdleScans: 0,
            backend: "NSBackgroundActivityScheduler"
        )

        // V2: run startup maintenance once, detached so it does not block the
        // health probe / ready emission. Runs through the gate so writes are
        // serialized with incoming commands. This also drains the FTS backlog
        // (via IndexJobRunner) so search content is actually written.
        let initialScanTask = Task {
            await Self.runStartupMaintenanceWithMemoryRelief {
                await Self.runInitialScan(
                    gate: gate,
                    statusMonitor: statusMonitor,
                    telemetry: telemetry,
                    environment: environment,
                    archiveV2Coordinator: archiveV2Coordinator,
                    archiveV2CaptureEnabled: await archiveV2Coordinator.captureEnabled,
                    tokenLimitsProvider: { Self.readUsageTokenLimits(environment: environment) },
                    testHooks: InitialScanTestHooks()
                )
                // First product caller of observability retention. Restart-cadence
                // prune is adequate (the legacy metrics writer is dormant, so this
                // is largely a one-time backlog cleanup of unbounded tables).
                await Self.runObservabilityRetention(gate: gate)
            }
        }

        // Opt-in remote session offload (default OFF). When enabled, the indexing
        // loop drains the offload/rehydrate queues and reclaims disk via VACUUM.
        let remoteSync = try RemoteSyncCoordinator.makeIfEnabled(gate: gate, environment: environment)
        if remoteSync != nil {
            ServiceLogger.info("remote offload enabled; wiring into indexing loop", category: .runner)
        }
        // Live ingest builds the same backend even when offload is off. Never
        // pass this coordinator to runOnce / drainOffload (invariant 16).
        let liveSync = try RemoteSyncCoordinator.makeLiveIfEnabled(gate: gate, environment: environment)
        if liveSync != nil {
            ServiceLogger.info("live ingest armed; publish/pull loop only (no offload runOnce)", category: .runner)
        }
        let livePublishSignal = LiveIngestPublishSignal()

        let indexingTask = Task {
            await Self.runAfterInitialScan(initialScanTask: initialScanTask) {
                await Self.runIndexingLoop(
                    gate: gate,
                    statusMonitor: statusMonitor,
                    telemetry: telemetry,
                    environment: environment,
                    archiveV2Coordinator: archiveV2Coordinator,
                    tokenLimitsProvider: { Self.readUsageTokenLimits(environment: environment) },
                    remoteSync: remoteSync,
                    livePublishSignal: livePublishSignal
                )
            }
        }
        let liveIngestTask = Task {
            await Self.runLiveIngestLoop(
                coordinator: liveSync,
                gate: gate,
                environment: environment,
                publisherReadyTask: initialScanTask,
                publishSignal: livePublishSignal
            )
        }
        let archiveDrainStartTask = Task {
            await initialScanTask.value
            guard !Task.isCancelled, let archiveV2Drainer else { return }
            // Rebuild the in-memory exact-index scheduler from the durable
            // capture catalog and file_index_state after every service restart.
            // Refreshing the full locator snapshot avoids stranding a retry if
            // the prior process stopped after advancing its capture cursor.
            await archiveV2Coordinator.requestFullCaptureSweep()
            await archiveV2Drainer.start()
            await archiveV2Drainer.signal()
        }

        // Best-effort startup TRUNCATE: PASSIVE never shrinks the WAL file on
        // disk, so without this the file grows monotonically. Created AFTER
        // ready is emitted on stdout/os_log so a reader-busy stall (TRUNCATE
        // invokes the writer's busy_handler, unlike PASSIVE) cannot delay the
        // launcher's 5s health probe and trigger a restart loop. The gate's
        // writeSemaphore serializes this with any incoming write commands;
        // busy != 0 is a normal outcome.
        let truncateTask = Task {
            do {
                let result = try await gate.checkpointTruncate(waitForReaders: false)
                if result.busy == 0 {
                    ServiceLogger.notice(
                        "startup wal truncate succeeded: log=\(result.logFrames) checkpointed=\(result.checkpointed)",
                        category: .checkpoint
                    )
                } else {
                    ServiceLogger.info(
                        "startup wal truncate skipped (reader busy): log=\(result.logFrames) checkpointed=\(result.checkpointed)",
                        category: .checkpoint
                    )
                }
            } catch {
                ServiceLogger.warn(
                    "startup wal truncate failed; falling back to periodic PASSIVE: \(error.localizedDescription)",
                    category: .checkpoint
                )
            }
        }

        let checkpointTask = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                do {
                    try await gate.checkpointWal()
                    ServiceLogger.info("wal checkpoint succeeded (mode=PASSIVE)", category: .checkpoint)
                    emit(ServiceCheckpointEvent(mode: "PASSIVE", ok: true, error: nil))
                } catch {
                    ServiceLogger.error(
                        "wal checkpoint failed (mode=PASSIVE)",
                        category: .checkpoint,
                        error: error
                    )
                    emit(ServiceCheckpointEvent(mode: "PASSIVE", ok: false, error: error.localizedDescription))
                }
            }
        }

        defer {
            initialScanTask.cancel()
            indexingTask.cancel()
            liveIngestTask.cancel()
            archiveDrainStartTask.cancel()
            checkpointTask.cancel()
            server.stop()
        }

        do {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch is CancellationError {
            // Fall through to the same shutdown path as an orderly stop.
        }
        // Stop accepting commands before cancelling any service-owned work.
        // Existing client handlers are cancelled by stop() and remain tracked
        // until their defers run, so the bounded drain below is observable.
        server.stop()
        await gate.beginShutdown()

        // Cancel and wait for in-flight gate write commands to unwind before the
        // gate is torn down, so the writer/process flocks are released for the
        // next launch. These are unstructured Tasks (not auto-cancelled when the
        // parent `run()` task is cancelled), so cancel them explicitly here.
        // The initial scan and periodic loop both hold the gate's write
        // semaphore through `performWriteCommand`; cancellation is observed at
        // the indexer's `Task.checkCancellation()` boundaries, so these return
        // promptly once cancelled. Without this, a still-running scan keeps the
        // gate alive (and its locks held) past `run()` returning.
        initialScanTask.cancel()
        indexingTask.cancel()
        liveIngestTask.cancel()
        archiveDrainStartTask.cancel()
        checkpointTask.cancel()
        truncateTask.cancel()
        let archiveStopTask = Task {
            await archiveV2Drainer?.stop()
        }
        let clientHandlersDrained = await server.drainClientHandlers(
            timeoutNanoseconds: 2_000_000_000
        )
        await initialScanTask.value
        await indexingTask.value
        await liveIngestTask.value
        await archiveDrainStartTask.value
        await archiveStopTask.value

        // PASSIVE checkpoint calls do not observe Swift task cancellation while
        // SQLite is executing. Await the task result so a periodic checkpoint
        // cannot overlap either remaining TRUNCATE operation below.
        await cancelAndAwaitCheckpointTask(checkpointTask)

        // Startup TRUNCATE uses busy_timeout=0, so this wait cannot hold a
        // SIGTERM shutdown behind a reader for the normal 30-second timeout.
        await truncateTask.value

        if !clientHandlersDrained {
            ServiceLogger.warn(
                "shutdown client handlers exceeded the bounded drain; waiting for service writers",
                category: .checkpoint
            )
        }

        // Detached project migration/title regeneration producers outlive their
        // cancelled client waiter. docs/invariants.md #1 requires the service process to
        // retain the single-writer lock until every such writer has left the
        // gate; otherwise main.swift can exit while SQLite is still mutating.
        await waitForShutdownWriterIdle(gate: gate)

        // Once every writer is gone, issue one nonblocking TRUNCATE. A live
        // reader reports busy immediately instead of delaying SIGTERM shutdown.
        do {
            let result = try await runShutdownCheckpoint {
                try await gate.checkpointTruncate(waitForReaders: false)
            }
            ServiceLogger.notice(
                "shutdown wal truncate: busy=\(result.busy) log=\(result.logFrames) checkpointed=\(result.checkpointed)",
                category: .checkpoint
            )
        } catch {
            ServiceLogger.warn(
                "shutdown wal truncate failed: \(error.localizedDescription)",
                category: .checkpoint
            )
        }
    }

    static func cancelAndAwaitCheckpointTask<Success, Failure: Error>(
        _ task: Task<Success, Failure>
    ) async {
        task.cancel()
        _ = await task.result
    }

    static func runShutdownCheckpoint<Value: Sendable>(
        _ checkpoint: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await Task {
            try await checkpoint()
        }.value
    }

    static func waitForShutdownWriterIdle(
        gate: ServiceWriterGate,
        pollNanoseconds: UInt64 = 20_000_000
    ) async {
        while !(await gate.isIdleForShutdown()) {
            // The runner task is already cancelled on SIGTERM. Sleep in a fresh
            // task so cancellation does not turn this cooperative wait into a
            // hot loop while detached long writes finish.
            await Task.detached {
                try? await Task.sleep(nanoseconds: pollNanoseconds)
            }.value
        }
    }

    /// Builds the single Archive V2 composition-root actor. Internal so focused
    /// integration tests can prove the default-off path has no storage effects.
    static func makeArchiveV2Coordinator(
        gate: ServiceWriterGate,
        databasePath: String,
        settings: ArchiveV2Settings,
        settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".engram/settings.json"),
        environment: [String: String] = [:]
    ) -> ArchiveV2ServiceCoordinator {
        return ArchiveV2ServiceCoordinator.make(
            settings: settings,
            databasePath: databasePath,
            writerGate: gate,
            settingsURL: settingsURL,
            environment: environment
        )
    }

    /// Prevent the periodic task from entering its first scheduling cycle until
    /// all initial-scan work (including bounded archive capture) has unwound.
    /// Cancellation while waiting must stop the next phase from starting.
    static func runAfterInitialScan(
        initialScanTask: Task<Void, Never>,
        operation: @escaping @Sendable () async -> Void
    ) async {
        await initialScanTask.value
        guard !Task.isCancelled else { return }
        await operation()
    }

    /// Startup indexing and maintenance intentionally create many short-lived
    /// parser/GRDB allocations. Run pressure relief only after that operation
    /// has returned, so its local snapshots and buffers have unwound before the
    /// allocator is asked to return empty pages to macOS.
    static func runStartupMaintenanceWithMemoryRelief(
        relieveMemoryPressure: @Sendable () -> Int = {
            Int(malloc_zone_pressure_relief(nil, 0))
        },
        operation: () async -> Void
    ) async {
        await operation()
        let releasedBytes = relieveMemoryPressure()
        ServiceLogger.notice(
            "startup memory pressure relief complete: releasedBytes=\(releasedBytes)",
            category: .runner
        )
    }

    static func runPeriodicMaintenanceWithMemoryRelief(
        relieveMemoryPressure: @Sendable () -> Int = {
            Int(malloc_zone_pressure_relief(nil, 0))
        },
        operation: () async -> Void
    ) async {
        await operation()
        let releasedBytes = relieveMemoryPressure()
        ServiceLogger.info(
            "periodic memory pressure relief complete: releasedBytes=\(releasedBytes)",
            category: .runner
        )
    }

    static func runArchiveV2IndexCycle(
        coordinator: ArchiveV2ServiceCoordinator?,
        captureAdapters: [any SessionAdapter],
        indexingAdapters: [any SessionAdapter],
        cursorScope: ArchiveCaptureCursorScope,
        indexOperation: @escaping @Sendable (
            [any SessionAdapter]
        ) async throws -> EngramDatabaseIndexResult
    ) async throws -> ArchiveV2ServiceCycleResult {
        guard let coordinator else {
            let result = try await indexOperation(indexingAdapters)
            return ArchiveV2ServiceCycleResult(
                indexResult: result,
                indexPlan: .unrestricted
            )
        }
        return try await coordinator.runCycle(
            adapters: captureAdapters,
            cursorScope: cursorScope
        ) { plan in
            try await indexOperation(
                SessionAdapterFactory.indexingAdapters(
                    from: indexingAdapters,
                    capturedExactLocators: plan.capturedExactLocators
                )
            )
        }
    }

    /// Exact-archive conformance is the capture eligibility boundary. Deriving
    /// this projection from the already-disabled-filtered indexing list keeps
    /// source opt-outs identical on both paths while leaving unsupported source
    /// adapters available to the product indexer.
    static func exactArchiveAdapters(
        from adapters: [any SessionAdapter]
    ) -> [any SessionAdapter] {
        adapters.filter { $0 is any ExactArchiveSourceAdapter }
    }

    /// Compose the bounded recent-window adapters with any exact locators that
    /// need another archive-capture attempt. The coordinator remains the owner
    /// of retry state and applies its configured per-source batch bound; the
    /// factory applies the same absolute safety cap before creating adapters.
    static func recentAdaptersForPeriodicCycle(
        archiveV2Coordinator: ArchiveV2ServiceCoordinator?,
        disabledSources: Set<String>,
        now: Date = Date()
    ) async -> [any SessionAdapter] {
        let retryLocators = await archiveV2Coordinator?.recentCaptureRetryLocators(
            maximumPerSource: SessionAdapterFactory.maximumTransientRetryLocatorsPerSource
        ) ?? [:]
        return adaptersExcludingDisabled(
            SessionAdapterFactory.recentActiveAdapters(
                now: now,
                priorTransientRetryLocators: retryLocators,
                maximumRetryLocatorsPerSource:
                    SessionAdapterFactory.maximumTransientRetryLocatorsPerSource
            ),
            disabledSources: disabledSources
        )
    }

    struct ArchiveCaptureInputs {
        let adapters: [any SessionAdapter]
        let cursorScope: ArchiveCaptureCursorScope
    }

    static func archiveCaptureInputsForPeriodicCycle(
        coordinator: ArchiveV2ServiceCoordinator?,
        fullAdapters: [any SessionAdapter],
        recentAdapters: [any SessionAdapter]
    ) async -> ArchiveCaptureInputs {
        let continueFull = await coordinator?.needsFullCaptureContinuation() ?? false
        let sourceAdapters = continueFull ? fullAdapters : recentAdapters
        return ArchiveCaptureInputs(
            adapters: exactArchiveAdapters(from: sourceAdapters),
            cursorScope: continueFull ? .full : .recent
        )
    }

    /// Prune observability tables past their retention windows, through the
    /// single-writer gate so it serializes with indexing writes. The one-time
    /// backlog can be ~661k rows; delete it in bounded batches, each its own
    /// gated write transaction, so the prune neither holds the writer gate nor
    /// spikes the WAL for its whole duration. The gate is released between
    /// batches, letting user write commands interleave.
    private static func runObservabilityRetention(gate: ServiceWriterGate) async {
        let batchLimit = 5_000
        var total = 0
        do {
            while !Task.isCancelled {
                let deleted = try await gate.performWriteCommand(name: "observabilityRetention") { writer in
                    try writer.pruneObservabilityRetention(limit: batchLimit)
                }
                total += deleted.value
                if deleted.value == 0 { break }
            }
            ServiceLogger.notice(
                "observability retention complete: pruned=\(total)",
                category: .runner
            )
        } catch is CancellationError {
            return
        } catch {
            ServiceLogger.error("observability retention failed", category: .runner, error: error)
        }
    }

    private static func runUserDataBackupBestEffort(
        gate: ServiceWriterGate,
        environment: [String: String]
    ) async {
        do {
            let result = try await gate.performWriteCommand(name: "userDataBackup") { writer in
                try writer.runUserDataBackupIfNeeded(environment: environment)
            }.value
            switch result.status {
            case .created:
                ServiceLogger.notice(
                    "user data backup created: file=\(result.backupURL?.lastPathComponent ?? "unknown") rotated=\(result.deletedOldBackups)",
                    category: .runner
                )
            case .failedValidation:
                ServiceLogger.warn("user data backup failed validation; attempted file was removed", category: .runner)
            case .skippedFreshBackup:
                break
            }
        } catch is CancellationError {
            return
        } catch {
            ServiceLogger.error("user data backup failed", category: .runner, error: error)
        }
    }

    /// Periodic FTS5 segment merge. Each writer-gated call has a fixed page
    /// budget; a new merge cycle has a 24h floor, while an in-progress cycle
    /// advances one bounded step per indexing tick. Errors are isolated so a
    /// failed merge never aborts the loop.
    static func runPeriodicFtsOptimizeBestEffort(gate: ServiceWriterGate) async {
        do {
            let ran = try await gate.performWriteCommand(name: "periodicFtsOptimize") { writer in
                try writer.optimizeFtsIfDue()
            }.value
            if ran {
                ServiceLogger.notice("periodic FTS merge step completed", category: .runner)
            }
        } catch is CancellationError {
            return
        } catch {
            ServiceLogger.warn(
                "periodic FTS merge failed: \(error.localizedDescription)",
                category: .runner
            )
        }
    }

    /// Maintenance runs after the incremental index has already succeeded.
    /// Its failure is observable, but must not turn that successful scan into
    /// an index error or leave service health stale.
    @discardableResult
    static func runPeriodicPostIndexMaintenance<Value>(
        operation: () async throws -> Value,
        onSuccess: (Value?) async -> Void
    ) async -> Bool {
        let value: Value?
        do {
            value = try await operation()
        } catch is CancellationError {
            return false
        } catch {
            ServiceLogger.warn(
                "periodic post-index maintenance failed: \(error.localizedDescription)",
                category: .runner
            )
            value = nil
        }
        guard !Task.isCancelled else { return false }
        await onSuccess(value)
        return true
    }

    private struct PeriodicPostIndexMaintenanceSummary {
        let total: Int
        let todayParents: Int
        let ftsCompleted: Int
        let ftsNotApplicable: Int
        let repoCount: Int
    }

    static func signalLivePublishIfNeeded(
        gate: ServiceWriterGate,
        environment: [String: String],
        publishSignal: LiveIngestPublishSignal?
    ) async {
        guard let publishSignal else { return }
        let config = LiveIngestConfig.read(
            environment: environment,
            homeDirectory: RemoteSyncConfig.homeDirectory(environment: environment)
        )
        guard config.publishEnabled,
              config.isLiveIdentityValid,
              let peer = config.resolvedPeer else { return }
        do {
            let token = try await gate.performReadCommand(name: "livePublishDelta") { writer in
                try writer.read { db in
                    try OffloadRepo.livePublishDeltaToken(db, peer: peer)
                }
            }.value
            if let token {
                await publishSignal.signalIndexChange(token: token)
            }
        } catch is CancellationError {
            return
        } catch {
            ServiceLogger.error("live publish delta probe failed", category: .runner, error: error)
        }
    }

    static func runFtsDrainThenSignal(
        gate: ServiceWriterGate,
        environment: [String: String],
        publishSignal: LiveIngestPublishSignal?,
        drain: () async throws -> StartupIndexJobRecoveryResult
    ) async rethrows -> StartupIndexJobRecoveryResult {
        let value = try await drain()
        // The exact actual-delta identity excludes unrelated/no-op job writes
        // while still detecting readiness and eligibility/retraction changes.
        await signalLivePublishIfNeeded(
            gate: gate,
            environment: environment,
            publishSignal: publishSignal
        )
        return value
    }

    /// Dedicated HQ publish / Mac pull loop. Must never call `runOnce`.
    static func runLiveIngestLoop(
        coordinator: RemoteSyncCoordinator?,
        gate: ServiceWriterGate,
        environment: [String: String],
        publisherReadyTask: Task<Void, Never>? = nil,
        publishSignal: LiveIngestPublishSignal = LiveIngestPublishSignal(),
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) async {
        guard let coordinator else { return }
        let startupConfig = LiveIngestConfig.read(
            environment: environment,
            homeDirectory: RemoteSyncConfig.homeDirectory(environment: environment)
        )
        if startupConfig.publishEnabled, let publisherReadyTask {
            await publisherReadyTask.value
            guard !Task.isCancelled else { return }
        }
        var completePublishWalk = true
        if await runLiveIngestCycle(
            coordinator: coordinator,
            environment: environment,
            debouncePublish: true,
            completeWalk: completePublishWalk,
            sleep: sleep
        ) {
            completePublishWalk = false
        }
        while !Task.isCancelled {
            let config = LiveIngestConfig.read(
                environment: environment,
                homeDirectory: RemoteSyncConfig.homeDirectory(environment: environment)
            )
            let wake: LiveIngestPublishSignal.Wake
            do {
                wake = try await publishSignal.wait(
                    intervalNanoseconds: UInt64(config.intervalSeconds) * 1_000_000_000,
                    debounceNanoseconds: 60_000_000_000,
                    respondsToIndexChanges: config.publishEnabled && config.isLiveIdentityValid,
                    sleep: sleep
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let publishSucceeded = await runLiveIngestCycle(
                coordinator: coordinator,
                environment: environment,
                debouncePublish: false,
                completeWalk: completePublishWalk,
                sleep: sleep
            )
            if publishSucceeded {
                completePublishWalk = false
                await publishSignal.markPublished(through: wake.changeGeneration)
                // A DB/FTS continuation can land after the coordinator's final
                // remaining-row snapshot but before this old wake is acked.
                // Ack first, then level-probe the actual predicates so that
                // residual delta receives a fresh epoch and trailing debounce.
                await signalLivePublishIfNeeded(
                    gate: gate,
                    environment: environment,
                    publishSignal: publishSignal
                )
            }
        }
    }

    static func runLiveIngestCycle(
        coordinator: RemoteSyncCoordinator,
        environment: [String: String],
        debouncePublish: Bool,
        completeWalk: Bool,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) async -> Bool {
        let config = LiveIngestConfig.read(
            environment: environment,
            homeDirectory: RemoteSyncConfig.homeDirectory(environment: environment)
        )
        guard config.isArmed, config.isLiveIdentityValid else { return false }
        var publishSucceeded = false
        do {
            if config.publishEnabled {
                if debouncePublish {
                    try await sleep(60_000_000_000)
                    guard !Task.isCancelled else { return false }
                }
                var published = try await coordinator.publishLivePeer(
                    batch: config.publishBatch,
                    completeWalk: completeWalk
                )
                while !completeWalk, published.hasMorePublishableRows {
                    try Task.checkCancellation()
                    published = try await coordinator.publishLivePeer(
                        batch: config.publishBatch,
                        completeWalk: false
                    )
                }
                publishSucceeded = true
                ServiceLogger.info(
                    "live publish cycle: entries=\(published.publishedEntries) complete=\(published.complete) gen=\(published.generation)",
                    category: .runner
                )
            }
            if config.ingestEnabled {
                for source in config.sources {
                    let pulled = try await coordinator.pullLivePeer(peer: source)
                    ServiceLogger.info(
                        "live pull cycle: peer=\(source) imported=\(pulled.imported) occupancy=\(pulled.occupancySkipped) retracted=\(pulled.retracted) latched=\(pulled.shrinkGuardLatched)",
                        category: .runner
                    )
                }
            }
            return publishSucceeded
        } catch is CancellationError {
            return false
        } catch {
            ServiceLogger.error("live ingest cycle failed", category: .runner, error: error)
            return publishSucceeded
        }
    }

    static func runIndexingLoop(
        gate: ServiceWriterGate,
        statusMonitor: ServiceStatusMonitor,
        telemetry: ServiceTelemetryCollector? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        archiveV2Coordinator: ArchiveV2ServiceCoordinator? = nil,
        tokenLimitsProvider: @escaping @Sendable () -> [String: StartupUsageTokenLimits],
        remoteSync: RemoteSyncCoordinator? = nil,
        livePublishSignal: LiveIngestPublishSignal? = nil,
        activityScheduler: IndexingBackgroundActivityScheduling = NSIndexingBackgroundActivityScheduler()
    ) async {
        // Wave 7C S01: adaptive 15→30→60m + NSBackgroundActivityScheduler
        // (background QoS, tolerance, shouldDefer). Work runs *inside* the
        // activity so OS completion fires only after the scan cycle ends.
        let scheduleBox = IndexingScheduleBox()
        // Explicit await invalidate at end so in-flight activity work exits
        // before the runner returns (matches gate cancel-and-wait contract).

        while !Task.isCancelled {
            let adaptiveSleepSeconds = scheduleBox.policy.nextInterval()
            let fileScanDueAt = Date().addingTimeInterval(adaptiveSleepSeconds)
            let enabledAdapters = adaptersExcludingDisabled(
                SessionAdapterFactory.defaultAdapters(),
                disabledSources: readDisabledSources(environment: environment)
            )
            let ftsRetryDelaySeconds = await nextFtsRetryDelaySeconds(
                gate: gate,
                adapters: enabledAdapters
            )
            let sleepSeconds = if let ftsRetryDelaySeconds {
                min(adaptiveSleepSeconds, max(ftsRetryDelaySeconds, 1))
            } else {
                adaptiveSleepSeconds
            }
            let ftsOnlyDue = ftsRetryDelaySeconds.map { $0 <= adaptiveSleepSeconds } ?? false
            // docs/invariants.md #5: an immediately due recovery retry is not
            // the next file-scan cadence. Publish the healthy minimum cadence
            // so a long FTS drain does not make status stale after one second.
            let publishedScheduleSeconds = Int(
                ftsOnlyDue ? IndexingSchedulePolicy.minInterval : sleepSeconds
            )
            await statusMonitor.recordSchedule(nextScanIntervalSeconds: publishedScheduleSeconds)
            await telemetry?.recordSchedule(
                nextScanIntervalSeconds: publishedScheduleSeconds,
                targetIntervalSeconds: Int(scheduleBox.policy.targetInterval),
                consecutiveIdleScans: scheduleBox.policy.consecutiveIdleScans,
                backend: activityScheduler.backendName
            )
            await archiveV2Coordinator?.recordNextScheduledCycle(
                at: Date().addingTimeInterval(sleepSeconds)
            )

            var fileScanSleepSeconds = sleepSeconds
            if ftsOnlyDue {
                // docs/invariants.md #5: due FTS recovery is non-discretionary;
                // NSBackgroundActivityScheduler remains the file-scan scheduler.
                do {
                    try await sleepBeforeFtsOnlyCycle(seconds: sleepSeconds)
                } catch is CancellationError {
                    break
                } catch {
                    ServiceLogger.error("scheduled FTS retry wait failed", category: .runner, error: error)
                }
                await Self.runFtsOnlyCycle(
                    gate: gate,
                    statusMonitor: statusMonitor,
                    adapters: enabledAdapters,
                    environment: environment,
                    livePublishSignal: livePublishSignal
                )
                await collectUsageBestEffort(gate: gate, tokenLimitsProvider: tokenLimitsProvider)
                do {
                    _ = try await refreshRepoDiscovery(
                        gate: gate,
                        phaseName: "ftsOnlyRepoDiscovery"
                    )
                } catch is CancellationError {
                    break
                } catch {
                    ServiceLogger.error("FTS-only repository discovery failed", category: .runner, error: error)
                }
                // The FTS retry borrowed an earlier wake-up from this file-scan
                // interval. Wait only the remaining time instead of rearming a
                // full adaptive interval and postponing an already-due scan.
                fileScanSleepSeconds = max(fileScanDueAt.timeIntervalSinceNow, 0)
            }

            let tolerance = min(5 * 60.0, fileScanSleepSeconds * 0.25)
            let opportunity = await activityScheduler.performWhenDue(
                interval: fileScanSleepSeconds,
                tolerance: tolerance
            ) {
                await Self.runPeriodicMaintenanceWithMemoryRelief {
                    let periodicCycle: @Sendable () async -> Void = {
                        await Self.runOnePeriodicIndexCycle(
                            gate: gate,
                            statusMonitor: statusMonitor,
                            telemetry: telemetry,
                            environment: environment,
                            archiveV2Coordinator: archiveV2Coordinator,
                            tokenLimitsProvider: tokenLimitsProvider,
                            remoteSync: remoteSync,
                            livePublishSignal: livePublishSignal,
                            scheduleBox: scheduleBox
                        )
                    }
                    if let archiveV2Coordinator {
                        await archiveV2Coordinator.withBacklogDrainPaused(periodicCycle)
                    } else {
                        await periodicCycle()
                    }
                }
            }
            if opportunity == .cancelled { break }
            if opportunity == .deferred {
                let disabled = readDisabledSources(environment: environment)
                let enabledAdapters = adaptersExcludingDisabled(
                    SessionAdapterFactory.defaultAdapters(),
                    disabledSources: disabled
                )
                do {
                    // docs/invariants.md #5: OS discretionary scheduling may
                    // defer scans, but must not indefinitely strand FTS recovery.
                    _ = try await runFtsDrainThenSignal(
                        gate: gate,
                        environment: environment,
                        publishSignal: livePublishSignal
                    ) {
                        try await drainRecoverableFtsJobs(
                            gate: gate,
                            adapters: enabledAdapters,
                            commandName: "deferredActivityFtsDrain",
                            onProgress: { await statusMonitor.recordScanDeferred() }
                        )
                    }
                } catch is CancellationError {
                    break
                } catch {
                    ServiceLogger.error("deferred-activity FTS drain failed", category: .runner, error: error)
                }
                await collectUsageBestEffort(gate: gate, tokenLimitsProvider: tokenLimitsProvider)
                do {
                    _ = try await refreshRepoDiscovery(
                        gate: gate,
                        phaseName: "deferredActivityRepoDiscovery"
                    )
                } catch is CancellationError {
                    break
                } catch {
                    ServiceLogger.error("deferred-activity repository discovery failed", category: .runner, error: error)
                }
                await statusMonitor.recordScanDeferred()
            }
            // .deferred / .run both continue the outer loop with updated schedule.
        }
        await activityScheduler.invalidate()
    }

    private static func nextFtsRetryDelaySeconds(
        gate: ServiceWriterGate,
        adapters: [any SessionAdapter]
    ) async -> TimeInterval? {
        do {
            let nanoseconds = try await gate.performReadCommand(name: "ftsRetrySchedule") { writer in
                try IndexJobRunner(writer: writer, adapters: adapters)
                    .recommendedFtsRetryDelayNanoseconds()
            }.value
            return nanoseconds.map { TimeInterval($0) / 1_000_000_000 }
        } catch {
            return nil
        }
    }

    private static func runFtsOnlyCycle(
        gate: ServiceWriterGate,
        statusMonitor: ServiceStatusMonitor,
        adapters: [any SessionAdapter],
        environment: [String: String],
        livePublishSignal: LiveIngestPublishSignal?
    ) async {
        do {
            _ = try await runFtsDrainThenSignal(
                gate: gate,
                environment: environment,
                publishSignal: livePublishSignal
            ) {
                try await drainRecoverableFtsJobs(
                    gate: gate,
                    adapters: adapters,
                    commandName: "scheduledFtsRetryDrain",
                    onProgress: { await statusMonitor.recordScanDeferred() }
                )
            }
            await statusMonitor.recordScanDeferred()
        } catch is CancellationError {
            return
        } catch {
            ServiceLogger.error("scheduled FTS retry drain failed", category: .runner, error: error)
        }
    }

    /// One adaptive scan cycle. Invoked only while an NSBackground activity is open.
    private static func runOnePeriodicIndexCycle(
        gate: ServiceWriterGate,
        statusMonitor: ServiceStatusMonitor,
        telemetry: ServiceTelemetryCollector?,
        environment: [String: String],
        archiveV2Coordinator: ArchiveV2ServiceCoordinator?,
        tokenLimitsProvider: @escaping @Sendable () -> [String: StartupUsageTokenLimits],
        remoteSync: RemoteSyncCoordinator?,
        livePublishSignal: LiveIngestPublishSignal?,
        scheduleBox: IndexingScheduleBox
    ) async {
        let processInfo = ProcessInfo.processInfo
        let conditions = IndexingSchedulePolicy.SystemConditions(
            lowPower: processInfo.isLowPowerModeEnabled,
            thermal: {
                switch processInfo.thermalState {
                case .nominal: return .nominal
                case .fair: return .fair
                case .serious: return .serious
                case .critical: return .critical
                @unknown default: return .fair
                }
            }()
        )
        if IndexingSchedulePolicy.shouldDefer(conditions: conditions) {
            let disabled = readDisabledSources(environment: environment)
            let enabledAdapters = adaptersExcludingDisabled(
                SessionAdapterFactory.defaultAdapters(),
                disabledSources: disabled
            )
            do {
                _ = try await runFtsDrainThenSignal(
                    gate: gate,
                    environment: environment,
                    publishSignal: livePublishSignal
                ) {
                    try await drainRecoverableFtsJobs(
                        gate: gate,
                        adapters: enabledAdapters,
                        commandName: "periodicFtsDrain",
                        onProgress: { await statusMonitor.recordScanDeferred() }
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                ServiceLogger.error("deferred-cycle FTS drain failed", category: .runner, error: error)
            }
            await collectUsageBestEffort(gate: gate, tokenLimitsProvider: tokenLimitsProvider)
            do {
                _ = try await refreshRepoDiscovery(
                    gate: gate,
                    phaseName: "deferredCycleRepoDiscovery"
                )
            } catch is CancellationError {
                return
            } catch {
                ServiceLogger.error("deferred-cycle repository discovery failed", category: .runner, error: error)
            }
            await statusMonitor.recordScanDeferred()
            return
        }

        let disabled = readDisabledSources(environment: environment)
        let recentAdapters = await recentAdaptersForPeriodicCycle(
            archiveV2Coordinator: archiveV2Coordinator,
            disabledSources: disabled
        )
        let enabledAdapters = adaptersExcludingDisabled(
            SessionAdapterFactory.defaultAdapters(),
            disabledSources: disabled
        )
        let captureInputs = await archiveCaptureInputsForPeriodicCycle(
            coordinator: archiveV2Coordinator,
            fullAdapters: enabledAdapters,
            recentAdapters: recentAdapters
        )
        let scanClock = ContinuousClock()
        let scanStarted = scanClock.now
        do {
            let archiveCycle = try await runArchiveV2IndexCycle(
                coordinator: archiveV2Coordinator,
                captureAdapters: captureInputs.adapters,
                indexingAdapters: recentAdapters,
                cursorScope: captureInputs.cursorScope
            ) { parserAdapters in
                try await gate.performWriteCommand(name: "indexRecent") { writer in
                    let excludedSnapshotSources = Set(
                        readDisabledSources(environment: environment)
                            .compactMap(SourceName.init(rawValue:))
                    )
                    return try await writer.indexRecentSessions(
                        adapters: parserAdapters,
                        excludedSnapshotSources: excludedSnapshotSources
                    )
                }.value
            }
            let scan = archiveCycle.indexResult
            scheduleBox.policy.recordScan(.init(indexed: scan.indexed, failed: false))

            let maintenanceCompleted = await runPeriodicPostIndexMaintenance {

            // Drain durable suggested-parent work even on an idle file scan.
            _ = try await gate.performWriteCommand(name: "periodicParentBackfills") { writer in
                try writer.runPeriodicParentBackfills()
            }

            // FTS drain has its own backlog gate — still OK after idle scans.
            let jobs = try await runFtsDrainThenSignal(
                gate: gate,
                environment: environment,
                publishSignal: livePublishSignal
            ) {
                try await drainRecoverableFtsJobs(
                    gate: gate,
                    adapters: enabledAdapters,
                    commandName: "periodicFtsDrain",
                    onProgress: { await statusMonitor.recordScanDeferred() }
                )
            }

            let shouldRunEmbeddingBackfill: Bool
            if scan.indexed > 0 {
                shouldRunEmbeddingBackfill = true
            } else {
                shouldRunEmbeddingBackfill = try await hasPendingEmbeddingBackfill(gate: gate)
            }
            if shouldRunEmbeddingBackfill {
                await runSessionEmbeddingBackfillBestEffort(
                    name: "periodicSessionEmbeddingBackfill",
                    gate: gate,
                    environment: environment
                )
                await runInsightEmbeddingBackfillBestEffort(
                    name: "periodicInsightEmbeddingBackfill",
                    gate: gate,
                    environment: environment
                )
            }

            if let remoteSync {
                do {
                    let sync = try await remoteSync.runOnce()
                    if sync.offloaded > 0 || sync.rehydrated > 0 || sync.reclaimedDisk {
                        ServiceLogger.notice(
                            "remote offload cycle: offloaded=\(sync.offloaded) rehydrated=\(sync.rehydrated) vacuumed=\(sync.reclaimedDisk)",
                            category: .runner
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    ServiceLogger.error("remote offload cycle failed", category: .runner, error: error)
                }
            }

            await archiveV2Coordinator?.reclamationCoordinatorSnapshot?.runAutomatically()

            await runUserDataBackupBestEffort(gate: gate, environment: environment)
            await runPeriodicFtsOptimizeBestEffort(gate: gate)

            let status = try await gate.performReadCommand(name: "periodicIndexStatus") { writer in
                try writer.indexStatus()
            }.value

            let repoCount = try await refreshRepoDiscovery(
                gate: gate,
                phaseName: "periodicRepoDiscovery"
            )

            return PeriodicPostIndexMaintenanceSummary(
                total: status.total,
                todayParents: status.todayParents,
                ftsCompleted: jobs.completed,
                ftsNotApplicable: jobs.notApplicable,
                repoCount: repoCount
            )
            } onSuccess: { summary in
                let total = summary?.total ?? scan.total
                let todayParents = summary?.todayParents ?? scan.todayParents
                ServiceLogger.notice(
                    "index scan completed: indexed=\(scan.indexed) total=\(total) todayParents=\(todayParents) ftsCompleted=\(summary?.ftsCompleted ?? 0) ftsNotApplicable=\(summary?.ftsNotApplicable ?? 0) repos=\(summary?.repoCount ?? 0)",
                    category: .runner
                )
                emit(ServiceIndexEvent(
                    indexed: scan.indexed,
                    total: total,
                    todayParents: todayParents
                ))
                await statusMonitor.recordScanSuccess()
                await telemetry?.recordScan(
                    durationMs: Self.elapsedMs(from: scanStarted, clock: scanClock),
                    indexed: scan.indexed,
                    total: total
                )
            }
            guard maintenanceCompleted else { return }
            await collectUsageBestEffort(gate: gate, tokenLimitsProvider: tokenLimitsProvider)
        } catch is CancellationError {
            return
        } catch {
            ServiceLogger.error("index scan failed", category: .runner, error: error)
            emit(ServiceIndexErrorEvent(error: error.localizedDescription))
            await statusMonitor.recordScanFailure(error.localizedDescription)
            scheduleBox.policy.recordScan(.init(indexed: 0, failed: true))
        }
    }

    private static func drainRecoverableFtsJobs(
        gate: ServiceWriterGate,
        adapters: [any SessionAdapter],
        commandName: String,
        onProgress: @escaping @Sendable () async -> Void = {}
    ) async throws -> StartupIndexJobRecoveryResult {
        // docs/invariants.md #5: periodic recovery must heal live FTS holes,
        // including rows whose prior terminal job no longer reflects the index.
        _ = try await gate.performWriteCommand(name: commandName) { writer in
            try WriterStartupBackfillDatabase(writer: writer).enqueueStaleFtsJobs()
        }
        // A single adapter stream can outlive the status stale threshold. Keep
        // the service heartbeat fresh while the writer gate drains that batch,
        // not only after the batch returns.
        let ftsDrainHeartbeat = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                } catch {
                    return
                }
                await onProgress()
            }
        }
        defer { ftsDrainHeartbeat.cancel() }
        var total = StartupIndexJobRecoveryResult(completed: 0, notApplicable: 0)
        while !Task.isCancelled {
            let drain = try await gate.performWriteCommand(name: commandName) { writer in
                let runner = IndexJobRunner(writer: writer, adapters: adapters)
                let once = try await runner.runRecoverableJobsOnce()
                return (
                    once,
                    try runner.recommendedFtsRetryDelayNanoseconds(),
                    try runner.shouldStopFtsDrainWave()
                )
            }.value
            total.completed += drain.0.result.completed
            total.notApplicable += drain.0.result.notApplicable
            await onProgress()
            if drain.0.drained { return total }
            if drain.2, let retryDelay = drain.1 {
                // docs/invariants.md #5: do not strand deferred retryable work
                // behind the next 15m periodic file-scan opportunity.
                try await Task.sleep(nanoseconds: retryDelay)
                continue
            }
            if drain.2 { return total }
            if let retryDelay = drain.1 {
                try await Task.sleep(nanoseconds: retryDelay)
            }
        }
        throw CancellationError()
    }

    private static func sleepBeforeFtsOnlyCycle(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Refresh repository counts on every indexing cycle while keeping expensive
    /// git metadata probes behind the bounded cooldown. Counting must not inherit
    /// the probe throttle because sessions can change while every cwd is cooling down.
    @discardableResult
    static func refreshRepoDiscovery(
        gate: ServiceWriterGate,
        throttle: RepoDiscoveryMaintenanceThrottle = .shared,
        probe: @escaping @Sendable (String) -> GitRepoProbe? = { RepoDiscovery.probeGit($0) },
        phaseName: String
    ) async throws -> Int {
        let snapshot = try await gate.performReadCommand(name: "\(phaseName)Candidates") { writer in
            try writer.read { db in
                let candidates = try RepoDiscovery.sessionCwdCounts(db, limit: Int.max)
                let forcedCwds = try RepoDiscovery.candidateCwdsMissingStoredRepoIdentity(
                    db,
                    candidates: candidates
                )
                return (candidates, forcedCwds)
            }
        }.value
        let dueCandidates = throttle.selectCandidates(
            snapshot.0,
            forcedCwds: snapshot.1
        )
        let batch = RepoDiscovery.probeRepositoriesDetailed(dueCandidates, probe: probe)
        let repoCount = try await gate.performWriteCommand(name: "\(phaseName)Recount") { writer in
            try writer.write { db in
                try RepoDiscovery.upsert(
                    db,
                    entries: batch.entries,
                    cwdToRepoPath: batch.cwdToRepoPath,
                    probedAt: ISO8601DateFormatter().string(from: Date())
                )
            }
        }.value

        let failed = Set(batch.failedCwds)
        throttle.recordOutcomes(
            succeeded: dueCandidates.compactMap { failed.contains($0.cwd) ? nil : $0.cwd },
            failed: batch.failedCwds
        )
        return repoCount
    }


/// Mutable adaptive schedule shared into @Sendable activity work closures.
private final class IndexingScheduleBox: @unchecked Sendable {
    var policy: IndexingSchedulePolicy

    init(policy: IndexingSchedulePolicy = IndexingSchedulePolicy()) {
        self.policy = policy
    }
}

    static func adaptersExcludingDisabled(
        _ adapters: [any SessionAdapter],
        disabledSources: Set<String>
    ) -> [any SessionAdapter] {
        adapters.filter { !disabledSources.contains($0.source.rawValue) }
    }

    /// Exact-archive adapters for one Archive V2 backlog pass. Always rereads
    /// the live disabled-source set so long-lived drainers honor mid-life toggles.
    static func exactArchiveAdaptersForBacklogPass(
        environment: [String: String],
        settingsURL: URL? = nil,
        adapters: [any SessionAdapter]? = nil
    ) -> [any SessionAdapter] {
        exactArchiveAdapters(
            from: adaptersExcludingDisabled(
                adapters ?? SessionAdapterFactory.defaultAdapters(),
                disabledSources: readDisabledSources(
                    environment: environment,
                    settingsURL: settingsURL
                )
            )
        )
    }

    /// Test hooks for outer initial-scan orchestration (M02). Production uses defaults.
    struct InitialScanTestHooks: Sendable {
        /// When set, the required phase with this name fails before its operation runs.
        var failPhaseNamed: String? = nil
        /// Cap on `initialFtsDrain` while-loop iterations. `nil` = unbounded (production).
        /// Tests use a small bound so residual FTS work cannot hang when adapters are disabled.
        var maxFtsDrainIterations: Int? = nil
        /// Deterministic concurrency seam after startup snapshots disabled-source settings.
        var afterDisabledSourceConfigurationRead: (@Sendable () async -> Void)? = nil

        init(
            failPhaseNamed: String? = nil,
            maxFtsDrainIterations: Int? = nil,
            afterDisabledSourceConfigurationRead: (@Sendable () async -> Void)? = nil
        ) {
            self.failPhaseNamed = failPhaseNamed
            self.maxFtsDrainIterations = maxFtsDrainIterations
            self.afterDisabledSourceConfigurationRead = afterDisabledSourceConfigurationRead
        }
    }

    struct InitialScanInjectedPhaseFailure: Error, LocalizedError {
        let phase: String
        var errorDescription: String? { "injected failure for phase \(phase)" }
    }

    static func shouldStopInitialFtsDrain(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= 3
    }

    /// Archive-enabled startup path: capture exact source bytes before the
    /// full parser/index operation, then let the coordinator reconcile the
    /// captured generation outside the writer gate. Keeping this as a distinct
    /// phase preserves the legacy default-off ordering below.
    private static func runInitialArchiveV2IndexPhase(
        gate: ServiceWriterGate,
        statusMonitor: ServiceStatusMonitor,
        telemetry: ServiceTelemetryCollector?,
        archiveV2Coordinator: ArchiveV2ServiceCoordinator?,
        startupAdapters: [any SessionAdapter],
        forceReparseKnownFiles: Bool,
        environment: [String: String],
        testHooks: InitialScanTestHooks
    ) async -> InitialScanPhaseOutcome<ArchiveV2ServiceCycleResult> {
        let archiveAdapters = exactArchiveAdapters(from: startupAdapters)
        return await runInitialScanPhase(
            name: "initialScanIndex",
            statusMonitor: statusMonitor,
            telemetry: telemetry,
            testHooks: testHooks
        ) {
            try await runArchiveV2IndexCycle(
                coordinator: archiveV2Coordinator,
                captureAdapters: archiveAdapters,
                indexingAdapters: startupAdapters,
                cursorScope: .full
            ) { parserAdapters in
                try await gate.performWriteCommand(name: "initialScanIndex") { writer in
                    let excludedSnapshotSources = Set(
                        readDisabledSources(environment: environment)
                            .compactMap(SourceName.init(rawValue:))
                    )
                    return try await writer.indexAllSessions(
                        adapters: parserAdapters,
                        excludedSnapshotSources: excludedSnapshotSources,
                        forceReparseKnownFiles: forceReparseKnownFiles,
                        didFinishAdapter: { source in
                            let releasedBytes = Int(malloc_zone_pressure_relief(nil, 0))
                            ServiceLogger.notice(
                                "startup adapter memory pressure relief complete: source=\(source.rawValue) releasedBytes=\(releasedBytes)",
                                category: .runner
                            )
                        }
                    )
                }.value
            }
        }
    }

    /// V2 composition root: runs the startup scan once, draining the FTS
    /// backlog. Builds real conformers over the unit-tested static funcs and
    /// runs through the gate so writes serialize with command dispatch.
    /// Internal for M02 behavioral tests of success-scan gating after phase failure.
    static func runInitialScan(
        gate: ServiceWriterGate,
        statusMonitor: ServiceStatusMonitor,
        telemetry: ServiceTelemetryCollector? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        archiveV2Coordinator: ArchiveV2ServiceCoordinator? = nil,
        archiveV2CaptureEnabled: Bool = false,
        tokenLimitsProvider: @escaping @Sendable () -> [String: StartupUsageTokenLimits] = { [:] },
        testHooks: InitialScanTestHooks = InitialScanTestHooks()
    ) async {
        let scanClock = ContinuousClock()
        let scanStarted = scanClock.now
        // Feature #2 slice B — per-source ingest opt-out. Drop disabled sources
        // from the indexing adapter list so the service stops ingesting them.
        // Read once to choose physical adapters for this scan. Each write phase
        // separately rereads the set after acquiring ServiceWriterGate so a
        // post-parse reclassification cannot race a source toggle.
        let disabledConfiguration = readDisabledSourceConfiguration(environment: environment)
        await testHooks.afterDisabledSourceConfigurationRead?()
        let disabled = disabledConfiguration.disabled
        let allAdapters = SessionAdapterFactory.defaultAdapters(
            homeDirectory: SessionAdapterFactory.resolvedHomeDirectory(environment: environment)
        )
        let enabledAdapters = adaptersExcludingDisabled(
            allAdapters,
            disabledSources: disabled
        )
        // Orphan detection is accessibility-only. It must retain every shipped
        // adapter even when that source is disabled for parsing/indexing.
        let orphanAdapters = allAdapters
        let emitBackfill: (StartupBackfillEvent) -> Void = { event in
            guard event.event != "ready" else { return }
            Self.emit(StartupBackfillEventEnvelope(event: event))
        }
        var failedPhaseCount = 0
        /// True when the primary index phase completed without failure. Used for
        /// partial success status (M2) so a later non-fatal phase error does not
        /// pin the degraded banner until the first periodic cycle.
        var coreIndexSucceeded = false

        if !disabledConfiguration.implicitArchived.isEmpty {
            let visibilityPhase = await runInitialScanPhase(
                name: "initialArchivedDefaultOffVisibility",
                statusMonitor: statusMonitor,
                telemetry: telemetry,
                testHooks: testHooks
            ) {
                try await gate.performWriteCommand(name: "initialArchivedDefaultOffVisibility") { writer in
                    let currentDisabledConfiguration = readDisabledSourceConfiguration(
                        environment: environment
                    )
                    try writer.write { db in
                        for source in ArchivedDefaultOffSources.orderedIDs
                        where currentDisabledConfiguration.implicitArchived.contains(source) {
                            try db.execute(
                                sql: """
                                    UPDATE sessions
                                    SET hidden_at = datetime('now')
                                    WHERE source = ? AND hidden_at IS NULL
                                    """,
                                arguments: [source]
                            )
                        }
                    }
                }
            }
            if visibilityPhase.cancelled { return }
            if visibilityPhase.failed { failedPhaseCount += 1 }
        }

        let usageParserBackfillCheck = await runInitialScanPhase(
            name: "usageParserBackfillCheck",
            statusMonitor: statusMonitor,
            telemetry: telemetry,
            testHooks: testHooks
        ) {
            try await gate.performReadCommand(name: "usageParserBackfillCheck") { writer in
                try writer.read { db in
                    try UsageParserBackfillPolicy.needsBackfill(db)
                }
            }.value
        }
        if usageParserBackfillCheck.cancelled { return }
        if usageParserBackfillCheck.failed { failedPhaseCount += 1 }
        let usageParserBackfillNeeded = usageParserBackfillCheck.value ?? false
        let startupAdapters = enabledAdapters
        let parserAdapters: [any SessionAdapter]

        var startupIndexed = 0
        if archiveV2CaptureEnabled {
            // Capture exact source bytes before ANY startup parser runs. Archive
            // failures remain best-effort; index failures keep phase telemetry.
            let indexedPhase = await runInitialArchiveV2IndexPhase(
                gate: gate,
                statusMonitor: statusMonitor,
                telemetry: telemetry,
                archiveV2Coordinator: archiveV2Coordinator,
                startupAdapters: startupAdapters,
                forceReparseKnownFiles: usageParserBackfillNeeded,
                environment: environment,
                testHooks: testHooks
            )
            if indexedPhase.cancelled { return }
            if indexedPhase.failed {
                failedPhaseCount += 1
            } else {
                coreIndexSucceeded = true
            }
            if let archiveCycle = indexedPhase.value {
                startupIndexed = archiveCycle.indexResult.indexed
                if let capturedExactLocators = archiveCycle.indexPlan.capturedExactLocators {
                    parserAdapters = SessionAdapterFactory.indexingAdapters(
                        from: startupAdapters,
                        capturedExactLocators: capturedExactLocators
                    )
                } else {
                    parserAdapters = startupAdapters
                }
            } else {
                parserAdapters = startupAdapters
            }
        } else {
            parserAdapters = startupAdapters
        }

        // Phase 1 — structural backfills, split into THREE gated write
        // commands so the single write gate is RELEASED between them and
        // user write commands (project move, save_insight, manual link) can
        // interleave instead of waiting out the whole multi-minute scan. The
        // heavy re-index and the per-row orphan scan previously held the gate
        // for the entire run, so any user write queued in that window timed
        // out with WriterBusy.
        let instructionBackfillPhase = await runInitialScanPhase(
            name: "initialInstructionBackfill",
            statusMonitor: statusMonitor,
            telemetry: telemetry,
            testHooks: testHooks
        ) {
            try await gate.performWriteCommand(name: "initialInstructionBackfill") { writer in
                try await writer.indexInstructionBackfillSessions(adapters: parserAdapters).indexed
            }.value
        }
        if instructionBackfillPhase.cancelled { return }
        if instructionBackfillPhase.failed { failedPhaseCount += 1 }
        let instructionBackfilled = instructionBackfillPhase.value ?? 0

        let implementationBackfillPhase = await runInitialScanPhase(
            name: "initialImplementationBeatBackfill",
            statusMonitor: statusMonitor,
            telemetry: telemetry,
            testHooks: testHooks
        ) {
            try await gate.performWriteCommand(name: "initialImplementationBeatBackfill") { writer in
                try await writer.indexImplementationBeatBackfillSessions(adapters: parserAdapters).indexed
            }.value
        }
        if implementationBackfillPhase.cancelled { return }
        if implementationBackfillPhase.failed { failedPhaseCount += 1 }
        let implementationBackfilled = implementationBackfillPhase.value ?? 0

        if !archiveV2CaptureEnabled {
            // Preserve the established default-off execution exactly: targeted
            // backfills run before the full startup index, with the legacy thin
            // StartupBackfills wrapper and telemetry phase name unchanged.
            let indexedPhase = await runInitialScanPhase(
                name: "initialScanIndex",
                statusMonitor: statusMonitor,
                telemetry: telemetry,
                testHooks: testHooks
            ) {
                try await gate.performWriteCommand(name: "initialScanIndex") { writer in
                    let excludedSnapshotSources = Set(
                        readDisabledSources(environment: environment)
                            .compactMap(SourceName.init(rawValue:))
                    )
                    return try await StartupBackfills.runStartupIndex(
                        indexer: WriterStartupIndexing(
                            writer: writer,
                            adapters: parserAdapters,
                            excludedSnapshotSources: excludedSnapshotSources,
                            forceReparseKnownFiles: usageParserBackfillNeeded
                        )
                    )
                }.value
            }
            if indexedPhase.cancelled { return }
            if indexedPhase.failed {
                failedPhaseCount += 1
            } else {
                coreIndexSucceeded = true
            }
            startupIndexed = indexedPhase.value ?? 0
        }

        let indexed = instructionBackfilled + implementationBackfilled + startupIndexed

        let backfillsPhase = await runInitialScanPhase(
            name: "initialScanBackfills",
            statusMonitor: statusMonitor,
            telemetry: telemetry,
            testHooks: testHooks
        ) {
            try await gate.performWriteCommand(name: "initialScanBackfills") { writer in
                let excludedSnapshotSources = Set(
                    readDisabledSources(environment: environment)
                        .compactMap(SourceName.init(rawValue:))
                )
                try await StartupBackfills.runStartupMaintenanceAndParents(
                    indexed: indexed,
                    emit: emitBackfill,
                    log: OSLogStartupBackfillLogging(),
                    indexer: WriterStartupIndexing(
                        writer: writer,
                        adapters: parserAdapters,
                        excludedSnapshotSources: excludedSnapshotSources
                    ),
                    database: WriterStartupBackfillDatabase(writer: writer)
                )
            }
        }
        if backfillsPhase.cancelled { return }
        if backfillsPhase.failed { failedPhaseCount += 1 }

        let orphanPhase = await runInitialScanPhase(
            name: "initialScanOrphans",
            statusMonitor: statusMonitor,
            telemetry: telemetry,
            testHooks: testHooks
        ) {
            try await gate.performWriteCommand(name: "initialScanOrphans") { writer in
                try await StartupBackfills.runStartupOrphanScan(
                    emit: emitBackfill,
                    log: OSLogStartupBackfillLogging(),
                    orphanScanner: WriterStartupOrphanScanning(writer: writer),
                    database: WriterStartupBackfillDatabase(writer: writer),
                    adapters: orphanAdapters
                )
            }
        }
        if orphanPhase.cancelled { return }
        if orphanPhase.failed { failedPhaseCount += 1 }

        // Phase 2 — drain the FTS backlog one batch per gated command, so a
        // large (100k+) drain releases the single write gate BETWEEN batches
        // and user write commands can interleave instead of failing with
        // WriterBusy after the gate is held for the whole scan.
        var ftsDrainIterations = 0
        var consecutiveFtsDrainFailures = 0
        while !Task.isCancelled {
            if let maxDrain = testHooks.maxFtsDrainIterations, ftsDrainIterations >= maxDrain {
                // Test-only bound: production leaves maxFtsDrainIterations nil.
                break
            }
            ftsDrainIterations += 1
            let drainPhase = await runInitialScanPhase(
                name: "initialFtsDrain",
                statusMonitor: statusMonitor,
                telemetry: telemetry,
                testHooks: testHooks
            ) {
                try await gate.performWriteCommand(name: "initialFtsDrain") { writer in
                    let runner = IndexJobRunner(writer: writer, adapters: startupAdapters)
                    let once = try await runner.runRecoverableJobsOnce()
                    return (
                        drained: once.drained,
                        retryDelayNanoseconds: try runner.recommendedFtsRetryDelayNanoseconds(),
                        stopCurrentWave: try runner.shouldStopFtsDrainWave()
                    )
                }.value
            }
            if drainPhase.cancelled { return }
            if drainPhase.failed {
                failedPhaseCount += 1
                consecutiveFtsDrainFailures += 1
                // docs/invariants.md #5: startup recovery must not strand the
                // periodic 90-second retry loop behind an unbounded failing drain.
                if shouldStopInitialFtsDrain(
                    consecutiveFailures: consecutiveFtsDrainFailures
                ) {
                    break
                }
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(consecutiveFtsDrainFailures) * 250_000_000
                    )
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
                continue
            }
            consecutiveFtsDrainFailures = 0
            if drainPhase.value?.drained ?? true { break }
            if drainPhase.value?.stopCurrentWave ?? false,
               let retryDelay = drainPhase.value?.retryDelayNanoseconds {
                // docs/invariants.md #5: startup recovery owns this bounded wait.
                try? await Task.sleep(nanoseconds: retryDelay)
                continue
            }
            if drainPhase.value?.stopCurrentWave ?? false { break }
            if let retryDelay = drainPhase.value?.retryDelayNanoseconds {
                try? await Task.sleep(nanoseconds: retryDelay)
            }
        }

        await runSessionEmbeddingBackfillBestEffort(
            name: "initialSessionEmbeddingBackfill",
            gate: gate,
            environment: environment
        )

        await runInsightEmbeddingBackfillBestEffort(
            name: "initialInsightEmbeddingBackfill",
            gate: gate,
            environment: environment
        )

        do {
            _ = try await refreshRepoDiscovery(
                gate: gate,
                phaseName: "initialRepoDiscovery"
            )
        } catch is CancellationError {
            return
        } catch {
            ServiceLogger.error("initial repository discovery failed", category: .runner, error: error)
            failedPhaseCount += 1
        }

        // Phase 3 — usage collection is cheap, but still gets its own gated
        // command so startup maintenance does not hold the writer gate longer.
        await collectUsageBestEffort(gate: gate, tokenLimitsProvider: tokenLimitsProvider)
        if usageParserBackfillNeeded && coreIndexSucceeded {
            let markPhase = await runInitialScanPhase(
                name: "usageParserBackfillMark",
                statusMonitor: statusMonitor,
                telemetry: telemetry,
                testHooks: testHooks
            ) {
                try await gate.performWriteCommand(name: "usageParserBackfillMark") { writer in
                    try writer.write { db in
                        try UsageParserBackfillPolicy.markComplete(db)
                    }
                }
            }
            if markPhase.cancelled { return }
            if markPhase.failed { failedPhaseCount += 1 }
        }

        // M02 telemetry: only record a success scan sample when every required
        // phase succeeded. Failed phases already recorded distinct failure
        // telemetry. M2 status: when the core index phase succeeded, still
        // clear the degraded banner via recordScanSuccess so a single non-fatal
        // later phase does not pin degraded for ≥15 min.
        // Best-effort completion status; a read failure must not affect scan
        // success accounting. Only a successful core scan publishes indexed,
        // matching the status monitor's partial-success rule below.
        let completionStatus = try? await gate.performReadCommand(name: "initialScanCompletionStatus") { writer in
            try writer.indexStatus()
        }.value
        if failedPhaseCount == 0 || coreIndexSucceeded {
            emit(ServiceIndexEvent(
                indexed: indexed,
                total: completionStatus?.total ?? 0,
                todayParents: completionStatus?.todayParents ?? 0
            ))
        }

        if failedPhaseCount == 0 {
            await telemetry?.recordScan(
                durationMs: Self.elapsedMs(from: scanStarted, clock: scanClock),
                indexed: indexed,
                total: completionStatus?.total ?? 0
            )
            ServiceLogger.notice("initial startup scan complete", category: .runner)
            await statusMonitor.recordScanSuccess()
        } else if coreIndexSucceeded {
            ServiceLogger.warn(
                "initial startup scan complete with \(failedPhaseCount) failed phase(s); core index succeeded (partial success)",
                category: .runner
            )
            await statusMonitor.recordScanSuccess()
        } else {
            ServiceLogger.warn(
                "initial startup scan complete with \(failedPhaseCount) failed phase(s)",
                category: .runner
            )
        }
    }

    /// Elapsed milliseconds between a `ContinuousClock` instant and now.
    private static func elapsedMs(from start: ContinuousClock.Instant, clock: ContinuousClock) -> Double {
        let components = start.duration(to: clock.now).components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    struct InitialScanPhaseOutcome<Value> {
        var value: Value?
        var failed: Bool
        var cancelled: Bool
    }

    /// Runs one required initial-scan phase with writerBusy retry + failure telemetry.
    /// Internal for focused M02 behavioral tests (operation failure → no success sample).
    static func runInitialScanPhase<Value>(
        name: String,
        statusMonitor: ServiceStatusMonitor,
        telemetry: ServiceTelemetryCollector? = nil,
        testHooks: InitialScanTestHooks = InitialScanTestHooks(),
        maxWriterBusyRetries: Int = 3,
        relieveMemoryPressure: @Sendable () -> Int = {
            Int(malloc_zone_pressure_relief(nil, 0))
        },
        operation: () async throws -> Value
    ) async -> InitialScanPhaseOutcome<Value> {
        defer {
            let releasedBytes = relieveMemoryPressure()
            ServiceLogger.notice(
                "startup phase memory pressure relief complete: phase=\(name) releasedBytes=\(releasedBytes)",
                category: .runner
            )
        }
        var writerBusyRetries = 0
        let phaseClock = ContinuousClock()
        let phaseStarted = phaseClock.now
        // Wall-clock start for span.startedAt (must reflect phase begin, not failure time).
        let phaseWallStartedAt = Self.isoTimestamp()
        while !Task.isCancelled {
            do {
                if testHooks.failPhaseNamed == name {
                    throw InitialScanInjectedPhaseFailure(phase: name)
                }
                let value = try await operation()
                return InitialScanPhaseOutcome(value: value, failed: false, cancelled: false)
            } catch is CancellationError {
                return InitialScanPhaseOutcome(value: nil, failed: false, cancelled: true)
            } catch {
                if isWriterBusy(error), writerBusyRetries < maxWriterBusyRetries {
                    writerBusyRetries += 1
                    ServiceLogger.warn(
                        "retrying startup phase \(name) after writerBusy (attempt \(writerBusyRetries)/\(maxWriterBusyRetries))",
                        category: .runner
                    )
                    let delayNanoseconds = UInt64(writerBusyRetries) * 2_000_000_000
                    do {
                        try await Task.sleep(nanoseconds: delayNanoseconds)
                    } catch {
                        return InitialScanPhaseOutcome(value: nil, failed: false, cancelled: true)
                    }
                    continue
                }

                let message = "\(name): \(error.localizedDescription)"
                ServiceLogger.error("startup phase failed: \(message)", category: .runner, error: error)
                emit(ServiceIndexErrorEvent(error: message))
                await statusMonitor.recordScanFailure(message)
                await telemetry?.recordFailedScanPhase(
                    phase: name,
                    durationMs: Self.elapsedMs(from: phaseStarted, clock: phaseClock),
                    startedAt: phaseWallStartedAt
                )
                return InitialScanPhaseOutcome(value: nil, failed: true, cancelled: false)
            }
        }
        return InitialScanPhaseOutcome(value: nil, failed: false, cancelled: true)
    }

    static func isoTimestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func isWriterBusy(_ error: Error) -> Bool {
        if case EngramServiceError.writerBusy = error {
            return true
        }
        return false
    }

    /// Default factory: OpenAI-compatible client wrapped by the process-shared
    /// embedding circuit breaker (N=5, 60s cooldown). Tests inject their own
    /// factory (often unguarded mocks) via the `providerFactory` parameter.
    static func defaultGuardedEmbeddingProvider(config: EmbeddingConfig) -> any EmbeddingProvider {
        GuardedEmbeddingProvider(
            config: config,
            breaker: EmbeddingGuardrails.sharedBreaker
        )
    }

    static func hasPendingEmbeddingBackfill(gate: ServiceWriterGate) async throws -> Bool {
        try await gate.performReadCommand(name: "periodicEmbeddingBacklog") { writer in
            if try !SessionEmbeddingBackfill.pendingSessions(writer: writer, limit: 1).isEmpty {
                return true
            }
            return try !InsightEmbeddingBackfill.pendingInsights(writer: writer, limit: 1).isEmpty
        }.value
    }

    @discardableResult
    static func backfillSessionEmbeddingsOnce(
        gate: ServiceWriterGate,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        providerFactory: @escaping @Sendable (EmbeddingConfig) -> any EmbeddingProvider = {
            EngramServiceRunner.defaultGuardedEmbeddingProvider(config: $0)
        },
        backoff: EmbeddingMaintenanceBackoff = .shared,
        limit: Int = 4,
        phaseName: String = "sessionEmbeddingBackfill"
    ) async throws -> Int {
        guard let config = EmbeddingSettings.load(environment: environment) else { return 0 }
        let providerKey = EmbeddingCircuitBreaker.providerKey(for: config)
        guard backoff.shouldAttempt(providerKey: providerKey) else {
            ServiceLogger.info(
                "\(phaseName) skipped: embedding maintenance cooldown remainingSeconds=\(Int(backoff.remainingDelay(providerKey: providerKey).rounded()))",
                category: .ai
            )
            return 0
        }
        let provider = providerFactory(config)
        let pending = try await gate.performReadCommand(name: "\(phaseName)Read") { writer in
            return try SessionEmbeddingBackfill.pendingSessions(writer: writer, limit: limit)
        }.value
        guard !pending.isEmpty else { return 0 }

        let outcome: SessionEmbeddingBackfill.EmbedBatchOutcome
        do {
            // M3: isolate per-session failures so one bad job does not abort the batch.
            outcome = try await SessionEmbeddingBackfill.embedPendingSessionsIsolated(
                pending,
                provider: provider
            )
        } catch EmbeddingError.circuitOpen {
            _ = backoff.recordFailure(providerKey: providerKey)
            // Soft skip: leave jobs pending/failed_retryable; never burn retry budget.
            ServiceLogger.info(
                "\(phaseName) skipped: embedding circuit open provider=\(EmbeddingCircuitBreaker.providerKey(for: config))",
                category: .ai
            )
            return 0
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as EmbeddingError {
            guard Self.isProviderScopedEmbeddingFailure(error) else { throw error }
            let delay = backoff.recordFailure(providerKey: providerKey)
            ServiceLogger.info(
                "\(phaseName) backing off provider after failure delaySeconds=\(Int(delay.rounded()))",
                category: .ai
            )
            throw error
        } catch {
            throw error
        }
        if outcome.embedded.isEmpty, !outcome.failures.isEmpty {
            // All failures here are item-local input rejections. Advance their
            // retry/terminal state without delaying unrelated jobs next cycle.
            _ = try await gate.performWriteCommand(name: "\(phaseName)Write") { writer in
                try SessionEmbeddingBackfill.writeEmbeddings(
                    writer: writer,
                    sessions: [],
                    model: provider.model,
                    dimension: provider.dimension,
                    failures: outcome.failures
                )
            }.value
            return 0
        }
        if !outcome.embedded.isEmpty {
            backoff.recordSuccess(providerKey: providerKey)
        }
        let result = try await gate.performWriteCommand(name: "\(phaseName)Write") { writer in
            try SessionEmbeddingBackfill.writeEmbeddings(
                writer: writer,
                sessions: outcome.embedded,
                model: provider.model,
                dimension: provider.dimension,
                failures: outcome.failures
            )
        }.value
        return result.completed
    }

    private static func isProviderScopedEmbeddingFailure(_ error: EmbeddingError) -> Bool {
        switch error {
        case .http, .malformedResponse, .dimensionMismatch, .notConfigured, .circuitOpen:
            return true
        case .inputRejected:
            return false
        }
    }

    private static func runSessionEmbeddingBackfillBestEffort(
        name: String,
        gate: ServiceWriterGate,
        environment: [String: String]
    ) async {
        do {
            let completed = try await backfillSessionEmbeddingsOnce(
                gate: gate,
                environment: environment,
                phaseName: name
            )
            if completed > 0 {
                ServiceLogger.notice("\(name) complete: completed=\(completed)", category: .runner)
            }
        } catch is CancellationError {
            return
        } catch EmbeddingError.circuitOpen {
            ServiceLogger.info("\(name) skipped: embedding circuit open", category: .ai)
        } catch {
            ServiceLogger.warn("\(name) failed: \(error.localizedDescription)", category: .runner)
        }
    }

    @discardableResult
    static func backfillInsightEmbeddingsOnce(
        gate: ServiceWriterGate,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        providerFactory: @escaping @Sendable (EmbeddingConfig) -> any EmbeddingProvider = {
            EngramServiceRunner.defaultGuardedEmbeddingProvider(config: $0)
        },
        backoff: EmbeddingMaintenanceBackoff = .shared,
        limit: Int = 16,
        phaseName: String = "insightEmbeddingBackfill"
    ) async throws -> Int {
        guard let config = EmbeddingSettings.load(environment: environment) else { return 0 }
        let providerKey = EmbeddingCircuitBreaker.providerKey(for: config)
        guard backoff.shouldAttempt(providerKey: providerKey) else {
            ServiceLogger.info(
                "\(phaseName) skipped: embedding maintenance cooldown remainingSeconds=\(Int(backoff.remainingDelay(providerKey: providerKey).rounded()))",
                category: .ai
            )
            return 0
        }
        let provider = providerFactory(config)
        let pending = try await gate.performReadCommand(name: "\(phaseName)Read") { writer in
            return try InsightEmbeddingBackfill.pendingInsights(writer: writer, limit: limit)
        }.value
        guard !pending.isEmpty else { return 0 }

        // R4: per-insight isolation outside the write gate (same contract as
        // session embed). Poison content fails one item; remaining continue;
        // permanent failures stop reselect via insight_embedding_failures.
        let outcome: (
            successes: [InsightEmbeddingBackfill.EmbeddedInsight],
            failures: [InsightEmbeddingBackfill.InsightFailure]
        )
        do {
            outcome = try await InsightEmbeddingBackfill.embedPendingIsolated(
                pending,
                provider: provider
            )
        } catch EmbeddingError.circuitOpen {
            _ = backoff.recordFailure(providerKey: providerKey)
            ServiceLogger.info(
                "\(phaseName) skipped: embedding circuit open provider=\(EmbeddingCircuitBreaker.providerKey(for: config))",
                category: .ai
            )
            return 0
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as EmbeddingError {
            guard Self.isProviderScopedEmbeddingFailure(error) else { throw error }
            let delay = backoff.recordFailure(providerKey: providerKey)
            ServiceLogger.info(
                "\(phaseName) backing off provider after failure delaySeconds=\(Int(delay.rounded()))",
                category: .ai
            )
            throw error
        } catch {
            throw error
        }

        if outcome.successes.isEmpty, outcome.failures.isEmpty {
            return 0
        }
        if !outcome.successes.isEmpty {
            backoff.recordSuccess(providerKey: providerKey)
        }

        let result = try await gate.performWriteCommand(name: "\(phaseName)Write") { writer in
            try InsightEmbeddingBackfill.writeEmbeddings(
                writer: writer,
                embeddings: outcome.successes,
                model: provider.model,
                dimension: provider.dimension,
                failures: outcome.failures
            ).embedded
        }.value
        return result
    }

    private static func runInsightEmbeddingBackfillBestEffort(
        name: String,
        gate: ServiceWriterGate,
        environment: [String: String]
    ) async {
        do {
            let embedded = try await backfillInsightEmbeddingsOnce(
                gate: gate,
                environment: environment,
                phaseName: name
            )
            if embedded > 0 {
                ServiceLogger.notice("\(name) complete: embedded=\(embedded)", category: .runner)
            }
        } catch is CancellationError {
            return
        } catch EmbeddingError.circuitOpen {
            ServiceLogger.info("\(name) skipped: embedding circuit open", category: .ai)
        } catch {
            ServiceLogger.warn("\(name) failed: \(error.localizedDescription)", category: .runner)
        }
    }

    @discardableResult
    static func collectUsage(
        gate: ServiceWriterGate,
        now: @escaping @Sendable () -> Date = { Date() },
        tokenLimits: [String: StartupUsageTokenLimits] = [:],
        emit: @escaping ([StartupUsageSnapshot]) -> Void = { snapshots in
            Self.emitUsageSnapshots(snapshots)
        }
    ) async throws -> [StartupUsageSnapshot] {
        try await collectUsageResult(
            gate: gate,
            now: now,
            tokenLimits: tokenLimits,
            emit: emit
        ).value
    }

    @discardableResult
    static func collectUsageResult(
        gate: ServiceWriterGate,
        now: @escaping @Sendable () -> Date = { Date() },
        tokenLimits: [String: StartupUsageTokenLimits] = [:],
        emit: @escaping ([StartupUsageSnapshot]) -> Void = { snapshots in
            Self.emitUsageSnapshots(snapshots)
        }
    ) async throws -> ServiceWriterGateResult<[StartupUsageSnapshot]> {
        let result = try await gate.performWriteCommand(name: "usageCollect") { writer in
            try WriterStartupUsageCollector(
                writer: writer,
                now: now,
                tokenLimits: tokenLimits
            ).collect()
        }
        if !result.value.isEmpty {
            emit(result.value)
        }
        return result
    }

    static func emitUsageSnapshots(_ snapshots: [StartupUsageSnapshot]) {
        Self.emit(ServiceUsageEvent(snapshots: snapshots))
    }

    private static func collectUsageBestEffort(
        gate: ServiceWriterGate,
        tokenLimitsProvider: @escaping @Sendable () -> [String: StartupUsageTokenLimits]
    ) async {
        do {
            try await collectUsage(gate: gate, tokenLimits: tokenLimitsProvider())
        } catch is CancellationError {
            return
        } catch {
            ServiceLogger.warn("usage collection failed: \(error.localizedDescription)", category: .runner)
        }
    }

    private static let stdoutLock = NSLock()

    /// Serialize every structured-JSON line written to stdout. Multiple startup
    /// tasks (initial scan, indexing loop, checkpoint) emit events concurrently;
    /// without a lock their `print()` + `fflush` can interleave or drop partial
    /// lines on the shared stdout stream.
    private static func writeStdoutLine(_ text: String) {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        print(text)
        fflush(stdout)
    }

    /// L01: encode stdout events with `JSONEncoder` so error/path text is always
    /// correctly escaped. Exposed for focused unit tests of escaping behavior.
    static func encodeStdoutJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw EngramServiceError.commandFailed(
                name: "StdoutEncodeFailed",
                message: "JSONEncoder produced non-UTF8 stdout payload",
                retryPolicy: "never",
                details: nil
            )
        }
        return text
    }

    private static func emit<T: Encodable>(_ value: T) {
        guard let text = try? encodeStdoutJSON(value) else {
            return
        }
        writeStdoutLine(text)
    }

    /// Reads the per-source ingest opt-out set (feature #2 slice B). A disabled
    /// source is dropped from the indexing adapter list at scan time, so the
    /// service stops ingesting it; its existing sessions are hidden separately by
    /// `setSourceEnabled`. An env override (`ENGRAM_DISABLED_SOURCES`,
    /// comma-separated source ids) is honored for tests/dev; otherwise the value
    /// comes from the `disabledSources` JSON string array in
    /// `~/.engram/settings.json`. Dormant archived sources default off until
    /// the settings file has been rewritten with the migration marker.
    static func readDisabledSources(
        environment: [String: String],
        settingsURL: URL? = nil
    ) -> Set<String> {
        readDisabledSourceConfiguration(
            environment: environment,
            settingsURL: settingsURL
        ).disabled
    }

    private struct DisabledSourceConfiguration {
        let disabled: Set<String>
        let implicitArchived: Set<String>
    }

    private static func readDisabledSourceConfiguration(
        environment: [String: String],
        settingsURL: URL? = nil
    ) -> DisabledSourceConfiguration {
        let settingsURL = settingsURL ?? engramSettingsURL(environment: environment)
        if let envValue = environment["ENGRAM_DISABLED_SOURCES"] {
            return DisabledSourceConfiguration(
                disabled: Set(
                    envValue
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                ),
                implicitArchived: []
            )
        }
        guard let data = SecureRegularFile.read(
            atPath: settingsURL.path,
            maximumBytes: 1024 * 1024,
            repairPermissions: true
        ),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return DisabledSourceConfiguration(
                disabled: ArchivedDefaultOffSources.ids,
                implicitArchived: ArchivedDefaultOffSources.ids
            )
        }
        guard let sources = object["disabledSources"] as? [Any] else {
            return DisabledSourceConfiguration(
                disabled: ArchivedDefaultOffSources.ids,
                implicitArchived: ArchivedDefaultOffSources.ids
            )
        }
        let explicitSources = Set(sources.compactMap { $0 as? String }.filter { !$0.isEmpty })
        guard object[ArchivedDefaultOffSources.settingsMigrationKey] as? Bool == true else {
            return DisabledSourceConfiguration(
                disabled: explicitSources.union(ArchivedDefaultOffSources.ids),
                implicitArchived: ArchivedDefaultOffSources.ids
            )
        }
        return DisabledSourceConfiguration(disabled: explicitSources, implicitArchived: [])
    }

    /// Reads explicit per-source token limits for local pressure snapshots.
    /// Env JSON wins for tests/dev; otherwise `~/.engram/settings.json` may
    /// contain `usageTokenLimits`.
    static func readUsageTokenLimits(
        environment: [String: String],
        settingsURL: URL? = nil
    ) -> [String: StartupUsageTokenLimits] {
        if let envValue = environment["ENGRAM_USAGE_TOKEN_LIMITS"],
           let limits = parseUsageTokenLimitsJSON(envValue) {
            return limits
        }
        let resolvedSettingsURL = settingsURL ?? engramSettingsURL(environment: environment)
        guard let data = SecureRegularFile.read(
            atPath: resolvedSettingsURL.path,
            maximumBytes: 1024 * 1024,
            repairPermissions: true
        ),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limitsObject = object["usageTokenLimits"] as? [String: Any]
        else {
            return [:]
        }
        return parseUsageTokenLimitsObject(limitsObject)
    }

    /// Resolve the settings file, honoring the `ENGRAM_SETTINGS_PATH` env
    /// override (tests point this at a temp file so per-source toggles can
    /// round-trip without clobbering the real `~/.engram/settings.json`).
    static func engramSettingsURL(environment: [String: String]) -> URL {
        if let override = environment["ENGRAM_SETTINGS_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return EngramServiceCommandHandler.ServiceAISettings.defaultSettingsPath(
            environment: environment
        )
    }

    static func removeLegacyWebUIToken(
        runtimeDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let dedicatedRuntimeDirectory = homeDirectory
            .appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .standardizedFileURL
        guard runtimeDirectory.standardizedFileURL.path == dedicatedRuntimeDirectory.path else {
            return
        }

        let tokenPath = dedicatedRuntimeDirectory.appendingPathComponent("webui.token").path
        guard SecureRegularFile.removeOwnerNonDirectory(atPath: tokenPath) else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private static func parseUsageTokenLimitsJSON(_ value: String) -> [String: StartupUsageTokenLimits]? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return parseUsageTokenLimitsObject(object)
    }

    private static func parseUsageTokenLimitsObject(_ object: [String: Any]) -> [String: StartupUsageTokenLimits] {
        object.reduce(into: [:]) { result, pair in
            let source = normalizedUsageSourceKey(pair.key)
            guard !source.isEmpty else { return }
            guard let sourceObject = pair.value as? [String: Any] else { return }
            let fiveHour = positiveDouble(sourceObject["fiveHourTokens"])
            let weekly = positiveDouble(sourceObject["weeklyTokens"])
            guard fiveHour != nil || weekly != nil else { return }
            result[source] = StartupUsageTokenLimits(fiveHourTokens: fiveHour, weeklyTokens: weekly)
        }
    }

    private static func normalizedUsageSourceKey(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func positiveDouble(_ value: Any?) -> Double? {
        let number: Double?
        switch value {
        case let value as Double:
            number = value
        case let value as Int:
            number = Double(value)
        case let value as NSNumber:
            number = value.doubleValue
        default:
            number = nil
        }
        guard let number, number.isFinite, number > 0 else {
            return nil
        }
        return number
    }

}

private struct StartupBackfillEventEnvelope: Encodable {
    let event: StartupBackfillEvent

    enum CodingKeys: String, CodingKey {
        case event
        case payload
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event.event, forKey: .event)
        try container.encode(event.payload, forKey: .payload)
    }
}

private struct ServiceIndexEvent: Encodable {
    let event = "indexed"
    let indexed: Int
    let total: Int
    let todayParents: Int
}

private struct ServiceIndexErrorEvent: Encodable {
    let event = "index_error"
    let error: String
}

private struct ServiceFatalEvent: Encodable {
    let event = "fatal"
    let stage: String
    let error: String
}

private struct ServiceReadyEvent: Encodable {
    let event = "listening"
    let socket: String
}

private struct ServiceCheckpointEvent: Encodable {
    let event = "checkpoint"
    let mode: String
    let ok: Bool
    let error: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event, forKey: .event)
        try container.encode(mode, forKey: .mode)
        try container.encode(ok, forKey: .ok)
        // Omit null error on success so the line stays compact; failures always include error.
        try container.encodeIfPresent(error, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case event, mode, ok, error
    }
}

struct ServiceUsageEvent: Encodable {
    struct Item: Encodable {
        let source: String
        let metric: String
        let value: Double
        let unit: String?
        let limit: Double?
        let resetAt: String?
        let status: String?
    }

    let event = "usage"
    let usage: [Item]

    init(snapshots: [StartupUsageSnapshot]) {
        self.usage = snapshots.map {
            Item(
                source: $0.source,
                metric: $0.metric,
                value: $0.value,
                unit: $0.unit,
                limit: $0.limit,
                resetAt: $0.resetAt,
                status: $0.status
            )
        }
    }
}
