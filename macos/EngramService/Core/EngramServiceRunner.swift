import Foundation
import GRDB
import EngramCoreRead
import EngramCoreWrite

private func argumentValue(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag),
          arguments.indices.contains(arguments.index(after: index)) else {
        return nil
    }
    return arguments[arguments.index(after: index)]
}

public enum EngramServiceRunner {
    public static func run(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        let socketPath = argumentValue(after: "--service-socket", in: arguments)
            ?? environment["ENGRAM_SERVICE_SOCKET"]
            ?? UnixSocketEngramServiceTransport.defaultSocketPath()
        let databasePath = argumentValue(after: "--database-path", in: arguments)
            ?? FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".engram", isDirectory: true)
                .appendingPathComponent("index.sqlite")
                .path

        let defaultSocketPath = UnixSocketEngramServiceTransport.defaultSocketPath()
        let runtimeDirectory: URL
        if socketPath == defaultSocketPath {
            runtimeDirectory = try UnixSocketEngramServiceTransport.secureRuntimeDirectory()
        } else {
            let socketURL = URL(fileURLWithPath: socketPath)
            runtimeDirectory = socketURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: databasePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try removeLegacyWebUIToken(runtimeDirectory: runtimeDirectory)
        } catch {
            ServiceLogger.warn("failed to remove legacy web UI token: \(error.localizedDescription)", category: .runner)
        }

        let socketBasename = URL(fileURLWithPath: socketPath).lastPathComponent
        let databaseBasename = URL(fileURLWithPath: databasePath).lastPathComponent

        ServiceLogger.info(
            "starting service: socket=\(socketBasename) database=\(databaseBasename)",
            category: .runner
        )

        let gate = try ServiceWriterGate(databasePath: databasePath, runtimeDirectory: runtimeDirectory)

        // Composition root: run migrations ONCE before serving (idempotent), and
        // fail fast if the schema is still absent afterward. A missing `sessions`
        // table means migrations did not actually create the schema, which would
        // otherwise surface as silent total:0 / empty results downstream.
        do {
            _ = try await gate.performWriteCommand(name: "migrate") { writer in
                try writer.migrate()
                try writer.verifySchemaPresent() // throws .missingSchema if schema absent
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
            settingsURL: engramSettingsURL(environment: environment),
            environment: environment
        )
        let archiveV2Coordinator = Self.makeArchiveV2Coordinator(
            gate: gate,
            databasePath: databasePath,
            settings: archiveV2Settings,
            settingsURL: engramSettingsURL(environment: environment),
            environment: environment
        )
        let archiveTranscriptResolver = archiveV2Coordinator.transcriptResolverSnapshot

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
            readProvider: try SQLiteEngramServiceReadProvider(databasePath: databasePath),
            statusMonitor: statusMonitor,
            telemetry: telemetry,
            logRing: logRing
        )
        let server = UnixSocketServiceServer(socketPath: socketPath) { request in
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
            await Self.runInitialScan(
                gate: gate,
                statusMonitor: statusMonitor,
                telemetry: telemetry,
                environment: environment,
                archiveV2Coordinator: archiveV2Coordinator,
                archiveV2CaptureEnabled: archiveV2Settings.exactArchiveEnabled,
                tokenLimitsProvider: { Self.readUsageTokenLimits(environment: environment) },
                testHooks: InitialScanTestHooks()
            )
            // First product caller of observability retention. Restart-cadence
            // prune is adequate (the legacy metrics writer is dormant, so this
            // is largely a one-time backlog cleanup of unbounded tables).
            await Self.runObservabilityRetention(gate: gate)
        }

        // Opt-in remote session offload (default OFF). When enabled, the indexing
        // loop drains the offload/rehydrate queues and reclaims disk via VACUUM.
        let remoteSync = RemoteSyncCoordinator.makeIfEnabled(gate: gate, environment: environment)
        if remoteSync != nil {
            ServiceLogger.info("remote offload enabled; wiring into indexing loop", category: .runner)
        }

        let indexingTask = Task {
            await Self.runAfterInitialScan(initialScanTask: initialScanTask) {
                await Self.runIndexingLoop(
                    gate: gate,
                    statusMonitor: statusMonitor,
                    telemetry: telemetry,
                    environment: environment,
                    archiveV2Coordinator: archiveV2Coordinator,
                    tokenLimitsProvider: { Self.readUsageTokenLimits(environment: environment) },
                    remoteSync: remoteSync
                )
            }
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
                let result = try await gate.checkpointTruncate()
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
        await initialScanTask.value
        await indexingTask.value

        // Wait for the startup truncate to finish before tearing down the gate.
        // SQLite's PRAGMA call doesn't observe Task cancellation, so the value
        // wait is what guarantees we don't drop the writer mid-checkpoint.
        // Bound by busy_timeout (30s) in the worst case; in practice <1s.
        await truncateTask.value

        // Final WAL TRUNCATE on graceful shutdown. The periodic checkpointTask
        // only runs PASSIVE (never shrinks the file on disk), so without this
        // accumulated WAL frames are left for the next startup's TRUNCATE,
        // leaving the WAL file large between runs. The gate's writeSemaphore
        // serializes this with any in-flight write; a reader-busy result
        // (busy != 0) is a normal best-effort outcome. SQLite's PRAGMA does not
        // observe Task cancellation; it is bounded by busy_timeout (30s).
        do {
            let result = try await gate.checkpointTruncate()
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

    /// Periodic FTS5 segment merge. Runs through the writer gate, reuses the
    /// content-signature + rebuild-version gates inside `optimizeFtsIfDue`,
    /// and adds a 24h attempt floor so a busy corpus does not re-merge on
    /// every 5-minute tick. Errors are isolated (match backup/embedding
    /// best-effort helpers) so a failed optimize never aborts the loop.
    static func runPeriodicFtsOptimizeBestEffort(gate: ServiceWriterGate) async {
        do {
            let ran = try await gate.performWriteCommand(name: "periodicFtsOptimize") { writer in
                try writer.optimizeFtsIfDue()
            }.value
            if ran {
                ServiceLogger.notice("periodic FTS optimize completed", category: .runner)
            }
        } catch is CancellationError {
            return
        } catch {
            ServiceLogger.warn(
                "periodic FTS optimize failed: \(error.localizedDescription)",
                category: .runner
            )
        }
    }

    private static func runIndexingLoop(
        gate: ServiceWriterGate,
        statusMonitor: ServiceStatusMonitor,
        telemetry: ServiceTelemetryCollector? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        archiveV2Coordinator: ArchiveV2ServiceCoordinator? = nil,
        tokenLimitsProvider: @escaping @Sendable () -> [String: StartupUsageTokenLimits],
        remoteSync: RemoteSyncCoordinator? = nil,
        activityScheduler: IndexingBackgroundActivityScheduling = NSIndexingBackgroundActivityScheduler()
    ) async {
        // Wave 7C S01: adaptive 15→30→60m + NSBackgroundActivityScheduler
        // (background QoS, tolerance, shouldDefer). Work runs *inside* the
        // activity so OS completion fires only after the scan cycle ends.
        let scheduleBox = IndexingScheduleBox()
        // Explicit await invalidate at end so in-flight activity work exits
        // before the runner returns (matches gate cancel-and-wait contract).

        while !Task.isCancelled {
            let sleepSeconds = scheduleBox.policy.nextInterval()
            await statusMonitor.recordSchedule(nextScanIntervalSeconds: Int(sleepSeconds))
            await telemetry?.recordSchedule(
                nextScanIntervalSeconds: Int(sleepSeconds),
                targetIntervalSeconds: Int(scheduleBox.policy.targetInterval),
                consecutiveIdleScans: scheduleBox.policy.consecutiveIdleScans,
                backend: activityScheduler.backendName
            )

            let tolerance = min(5 * 60.0, sleepSeconds * 0.25)
            let opportunity = await activityScheduler.performWhenDue(
                interval: sleepSeconds,
                tolerance: tolerance
            ) {
                await Self.runOnePeriodicIndexCycle(
                    gate: gate,
                    statusMonitor: statusMonitor,
                    telemetry: telemetry,
                    environment: environment,
                    archiveV2Coordinator: archiveV2Coordinator,
                    tokenLimitsProvider: tokenLimitsProvider,
                    remoteSync: remoteSync,
                    scheduleBox: scheduleBox
                )
            }
            if opportunity == .cancelled { break }
            // .deferred / .run both continue the outer loop with updated schedule.
        }
        await activityScheduler.invalidate()
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
                    try await writer.indexRecentSessions(adapters: parserAdapters)
                }.value
            }
            let scan = archiveCycle.indexResult
            let periodicParserAdapters: [any SessionAdapter]
            if let captured = archiveCycle.indexPlan.capturedExactLocators {
                periodicParserAdapters = SessionAdapterFactory.indexingAdapters(
                    from: recentAdapters,
                    capturedExactLocators: captured
                )
            } else {
                periodicParserAdapters = enabledAdapters
            }
            scheduleBox.policy.recordScan(.init(indexed: scan.indexed, failed: false))

            // Parent-link only after indexed changes (idle skip).
            if scan.indexed > 0 {
                _ = try await gate.performWriteCommand(name: "periodicParentBackfills") { writer in
                    try writer.runPeriodicParentBackfills()
                }
            }

            // FTS drain has its own backlog gate — still OK after idle scans.
            var jobs = StartupIndexJobRecoveryResult(completed: 0, notApplicable: 0)
            while !Task.isCancelled {
                let drain = try await gate.performWriteCommand(name: "periodicFtsDrain") { writer in
                    try await IndexJobRunner(writer: writer, adapters: periodicParserAdapters)
                        .runRecoverableJobsOnce()
                }.value
                jobs.completed += drain.result.completed
                jobs.notApplicable += drain.result.notApplicable
                if drain.drained { break }
            }

            // Wave 7C S01: idle scans must not start embedding backfills.
            if scan.indexed > 0 {
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
                    return
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

            var repoCount = 0
            if scan.indexed > 0 {
                let repoCandidates = try await gate.performWriteCommand(name: "periodicRepoCandidates") { writer in
                    try writer.read { db in
                        try RepoDiscovery.sessionCwdCounts(db)
                    }
                }.value
                let repoEntries = RepoDiscovery.probeRepositories(repoCandidates)
                repoCount = try await gate.performWriteCommand(name: "repoDiscoveryUpsert") { writer in
                    try writer.write { db in
                        try RepoDiscovery.upsert(
                            db,
                            entries: repoEntries,
                            probedAt: ISO8601DateFormatter().string(from: Date())
                        )
                    }
                }.value
            }

            ServiceLogger.notice(
                "index scan completed: indexed=\(scan.indexed) total=\(status.total) todayParents=\(status.todayParents) ftsCompleted=\(jobs.completed) ftsNotApplicable=\(jobs.notApplicable) repos=\(repoCount)",
                category: .runner
            )
            emit(ServiceIndexEvent(
                indexed: scan.indexed,
                total: status.total,
                todayParents: status.todayParents
            ))
            await statusMonitor.recordScanSuccess()
            await telemetry?.recordScan(
                durationMs: Self.elapsedMs(from: scanStarted, clock: scanClock),
                indexed: scan.indexed,
                total: status.total
            )
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


/// Mutable adaptive schedule shared into @Sendable activity work closures.
private final class IndexingScheduleBox: @unchecked Sendable {
    var policy: IndexingSchedulePolicy

    init(policy: IndexingSchedulePolicy = IndexingSchedulePolicy()) {
        self.policy = policy
    }
}

    private static func adaptersExcludingDisabled(
        _ adapters: [any SessionAdapter],
        disabledSources: Set<String>
    ) -> [any SessionAdapter] {
        adapters.filter { !disabledSources.contains($0.source.rawValue) }
    }

    /// Test hooks for outer initial-scan orchestration (M02). Production uses defaults.
    struct InitialScanTestHooks: Sendable {
        /// When set, the required phase with this name fails before its operation runs.
        var failPhaseNamed: String? = nil
        /// Cap on `initialFtsDrain` while-loop iterations. `nil` = unbounded (production).
        /// Tests use a small bound so residual FTS work cannot hang when adapters are disabled.
        var maxFtsDrainIterations: Int? = nil

        init(failPhaseNamed: String? = nil, maxFtsDrainIterations: Int? = nil) {
            self.failPhaseNamed = failPhaseNamed
            self.maxFtsDrainIterations = maxFtsDrainIterations
        }
    }

    struct InitialScanInjectedPhaseFailure: Error, LocalizedError {
        let phase: String
        var errorDescription: String? { "injected failure for phase \(phase)" }
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
                    try await writer.indexAllSessions(adapters: parserAdapters)
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
        // Read once at scan time, so toggling a source resumes/stops ingest on
        // the next scan. Their existing sessions are hidden by setSourceEnabled.
        let disabled = readDisabledSources(environment: environment)
        let enabledAdapters = adaptersExcludingDisabled(
            SessionAdapterFactory.defaultAdapters(),
            disabledSources: disabled
        )
        let emitBackfill: (StartupBackfillEvent) -> Void = { event in
            Self.emit(StartupBackfillEventEnvelope(event: event))
        }
        var failedPhaseCount = 0

        let usageParserBackfillCheck = await runInitialScanPhase(
            name: "usageParserBackfillCheck",
            statusMonitor: statusMonitor,
            telemetry: telemetry,
            testHooks: testHooks
        ) {
            try await gate.performWriteCommand(name: "usageParserBackfillCheck") { writer in
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
                testHooks: testHooks
            )
            if indexedPhase.cancelled { return }
            if indexedPhase.failed { failedPhaseCount += 1 }
            if let archiveCycle = indexedPhase.value {
                startupIndexed = archiveCycle.indexResult.indexed
                parserAdapters = SessionAdapterFactory.indexingAdapters(
                    from: startupAdapters,
                    capturedExactLocators: archiveCycle.indexPlan.capturedExactLocators ?? [:]
                )
            } else {
                parserAdapters = SessionAdapterFactory.indexingAdapters(
                    from: startupAdapters,
                    capturedExactLocators: [:]
                )
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
                    try await StartupBackfills.runStartupIndex(
                        indexer: WriterStartupIndexing(writer: writer, adapters: parserAdapters)
                    )
                }.value
            }
            if indexedPhase.cancelled { return }
            if indexedPhase.failed { failedPhaseCount += 1 }
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
                try await StartupBackfills.runStartupMaintenanceAndParents(
                    indexed: indexed,
                    emit: emitBackfill,
                    log: OSLogStartupBackfillLogging(),
                    indexer: WriterStartupIndexing(writer: writer, adapters: parserAdapters),
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
                    adapters: parserAdapters
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
                    try await IndexJobRunner(writer: writer, adapters: parserAdapters)
                        .runRecoverableJobsOnce()
                        .drained
                }.value
            }
            if drainPhase.cancelled { return }
            if drainPhase.failed {
                failedPhaseCount += 1
                break
            }
            if drainPhase.value ?? true { break }
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

        // Phase 3 — usage collection is cheap, but still gets its own gated
        // command so startup maintenance does not hold the writer gate longer.
        await collectUsageBestEffort(gate: gate, tokenLimitsProvider: tokenLimitsProvider)
        if usageParserBackfillNeeded {
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

        // M02: only record a success scan sample when every required phase
        // succeeded. Failed phases already recorded distinct failure telemetry.
        if failedPhaseCount == 0 {
            // Best-effort total via a gated indexStatus read; a failure here
            // must not affect scan success accounting.
            let initialTotal = (try? await gate.performReadCommand(name: "initialScanTelemetryStatus") { writer in
                try writer.indexStatus()
            }.value.total) ?? 0
            await telemetry?.recordScan(
                durationMs: Self.elapsedMs(from: scanStarted, clock: scanClock),
                indexed: indexed,
                total: initialTotal
            )
            ServiceLogger.notice("initial startup scan complete", category: .runner)
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
        operation: () async throws -> Value
    ) async -> InitialScanPhaseOutcome<Value> {
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

    @discardableResult
    static func backfillSessionEmbeddingsOnce(
        gate: ServiceWriterGate,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        providerFactory: @escaping @Sendable (EmbeddingConfig) -> any EmbeddingProvider = {
            EngramServiceRunner.defaultGuardedEmbeddingProvider(config: $0)
        },
        limit: Int = 32,
        phaseName: String = "sessionEmbeddingBackfill"
    ) async throws -> Int {
        guard let config = EmbeddingSettings.load(environment: environment) else { return 0 }
        let pending = try await gate.performWriteCommand(name: "\(phaseName)Read") { writer in
            try SessionEmbeddingBackfill.pendingSessions(writer: writer, limit: limit)
        }.value
        guard !pending.isEmpty else { return 0 }

        let provider = providerFactory(config)
        let embedded: [SessionEmbeddingBackfill.EmbeddedSession]
        do {
            embedded = try await SessionEmbeddingBackfill.embedPendingSessions(pending, provider: provider)
        } catch EmbeddingError.circuitOpen {
            // Soft skip: leave jobs pending/failed_retryable; never burn retry budget.
            ServiceLogger.info(
                "\(phaseName) skipped: embedding circuit open provider=\(EmbeddingCircuitBreaker.providerKey(for: config))",
                category: .ai
            )
            return 0
        }
        let result = try await gate.performWriteCommand(name: "\(phaseName)Write") { writer in
            try SessionEmbeddingBackfill.writeEmbeddings(
                writer: writer,
                sessions: embedded,
                model: provider.model,
                dimension: provider.dimension
            )
        }.value
        return result.completed
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
        limit: Int = 64,
        phaseName: String = "insightEmbeddingBackfill"
    ) async throws -> Int {
        guard let config = EmbeddingSettings.load(environment: environment) else { return 0 }
        let pending = try await gate.performWriteCommand(name: "\(phaseName)Read") { writer in
            try InsightEmbeddingBackfill.pendingInsights(writer: writer, limit: limit)
        }.value
        guard !pending.isEmpty else { return 0 }

        let provider = providerFactory(config)
        let vectors: [[Float]]
        do {
            vectors = try await provider.embed(pending.map(\.content))
        } catch EmbeddingError.circuitOpen {
            ServiceLogger.info(
                "\(phaseName) skipped: embedding circuit open provider=\(EmbeddingCircuitBreaker.providerKey(for: config))",
                category: .ai
            )
            return 0
        }
        guard vectors.count == pending.count else { return 0 }
        let embedded = zip(pending, vectors).map { item, vector in
            InsightEmbeddingBackfill.EmbeddedInsight(id: item.id, vector: vector)
        }

        let result = try await gate.performWriteCommand(name: "\(phaseName)Write") { writer in
            try InsightEmbeddingBackfill.writeEmbeddings(
                writer: writer,
                embeddings: embedded,
                model: provider.model,
                dimension: provider.dimension
            )
        }.value
        return result.embedded
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
        let settingsURL = settingsURL ?? engramSettingsURL(environment: environment)
        if let envValue = environment["ENGRAM_DISABLED_SOURCES"] {
            return Set(
                envValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
        }
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ArchivedDefaultOffSources.ids
        }
        guard let sources = object["disabledSources"] as? [Any] else {
            return ArchivedDefaultOffSources.ids
        }
        let explicitSources = Set(sources.compactMap { $0 as? String }.filter { !$0.isEmpty })
        guard object[ArchivedDefaultOffSources.settingsMigrationKey] as? Bool == true else {
            return explicitSources.union(ArchivedDefaultOffSources.ids)
        }
        return explicitSources
    }

    /// Reads explicit per-source token limits for local pressure snapshots.
    /// Env JSON wins for tests/dev; otherwise `~/.engram/settings.json` may
    /// contain `usageTokenLimits`.
    static func readUsageTokenLimits(
        environment: [String: String],
        settingsURL: URL = defaultEngramSettingsURL()
    ) -> [String: StartupUsageTokenLimits] {
        if let envValue = environment["ENGRAM_USAGE_TOKEN_LIMITS"],
           let limits = parseUsageTokenLimitsJSON(envValue) {
            return limits
        }
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limitsObject = object["usageTokenLimits"] as? [String: Any]
        else {
            return [:]
        }
        return parseUsageTokenLimitsObject(limitsObject)
    }

    private static func defaultEngramSettingsURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// Resolve the settings file, honoring the `ENGRAM_SETTINGS_PATH` env
    /// override (tests point this at a temp file so per-source toggles can
    /// round-trip without clobbering the real `~/.engram/settings.json`).
    static func engramSettingsURL(environment: [String: String]) -> URL {
        if let override = environment["ENGRAM_SETTINGS_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return defaultEngramSettingsURL()
    }

    static func removeLegacyWebUIToken(runtimeDirectory: URL) throws {
        let tokenURL = runtimeDirectory.appendingPathComponent("webui.token")
        guard FileManager.default.fileExists(atPath: tokenURL.path) else { return }
        try FileManager.default.removeItem(at: tokenURL)
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
    let event = "ready"
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
