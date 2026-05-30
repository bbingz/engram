import Foundation
import Security
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
            writeStdoutLine(#"{"event":"fatal","stage":"migrate","error":"\#(error.localizedDescription)"}"#)
            exit(70) // EX_SOFTWARE
        }

        let statusMonitor = ServiceStatusMonitor()
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            readProvider: try SQLiteEngramServiceReadProvider(databasePath: databasePath),
            statusMonitor: statusMonitor
        )
        let server = UnixSocketServiceServer(socketPath: socketPath) { request in
            await handler.handle(request)
        }
        try server.start()

        // SEC-C1: the web UI is opt-in. Default OFF; only start when the user has
        // explicitly enabled `webUIEnabled` in ~/.engram/settings.json.
        let webUIEnabled = Self.readWebUIEnabled(environment: environment)
        let webToken = webUIEnabled ? Self.provisionWebToken(runtimeDirectory: runtimeDirectory) : nil
        let webTask = webUIEnabled ? Task {
            do {
                let webServer = try EngramWebUIServer(databasePath: databasePath, authToken: webToken)
                let readyTask = Task {
                    do {
                        try await waitForWebHealth(host: "127.0.0.1", port: 3457)
                        emitWebReady(host: "127.0.0.1", port: 3457)
                    } catch is CancellationError {
                    } catch {
                        ServiceLogger.warn(
                            "web ui health probe failed: \(error.localizedDescription)",
                            category: .runner
                        )
                        emit(ServiceWebErrorEvent(message: error.localizedDescription))
                    }
                }
                defer {
                    readyTask.cancel()
                }
                try await webServer.run()
            } catch is CancellationError {
                return
            } catch {
                ServiceLogger.warn(
                    "web ui failed to start: \(error.localizedDescription)",
                    category: .runner
                )
                emit(ServiceWebErrorEvent(message: error.localizedDescription))
            }
        } : nil
        if !webUIEnabled {
            ServiceLogger.info("web ui disabled (webUIEnabled=false); not starting", category: .runner)
        }

        ServiceLogger.notice("service ready, listening on \(socketBasename)", category: .runner)
        writeStdoutLine(#"{"event":"ready","socket":"\#(socketPath)"}"#)

        // V2: run startup maintenance once, detached so it does not block the
        // health probe / ready emission. Runs through the gate so writes are
        // serialized with incoming commands. This also drains the FTS backlog
        // (via IndexJobRunner) so search content is actually written.
        let initialScanTask = Task {
            await Self.runInitialScan(gate: gate, statusMonitor: statusMonitor)
            // First product caller of observability retention. Restart-cadence
            // prune is adequate (the legacy metrics writer is dormant, so this
            // is largely a one-time backlog cleanup of unbounded tables).
            await Self.runObservabilityRetention(gate: gate)
        }

        let indexingTask = Task {
            await Self.runIndexingLoop(gate: gate, statusMonitor: statusMonitor)
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
                    writeStdoutLine(#"{"event":"checkpoint","mode":"PASSIVE","ok":true}"#)
                } catch {
                    ServiceLogger.error(
                        "wal checkpoint failed (mode=PASSIVE)",
                        category: .checkpoint,
                        error: error
                    )
                    writeStdoutLine(#"{"event":"checkpoint","mode":"PASSIVE","ok":false,"error":"\#(error.localizedDescription)"}"#)
                }
            }
        }

        defer {
            initialScanTask.cancel()
            indexingTask.cancel()
            checkpointTask.cancel()
            webTask?.cancel()
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
                    try writer.write { db in
                        try ObservabilityRetention.prune(db, limit: batchLimit)
                    }
                }
                total += deleted.value
                if deleted.value == 0 { break }
            }
            if total > 0 {
                ServiceLogger.notice(
                    "observability retention pruned \(total) rows",
                    category: .runner
                )
            }
        } catch is CancellationError {
            return
        } catch {
            ServiceLogger.error("observability retention failed", category: .runner, error: error)
        }
    }

    private static func runIndexingLoop(gate: ServiceWriterGate, statusMonitor: ServiceStatusMonitor) async {
        let intervalNanoseconds: UInt64 = 5 * 60 * 1_000_000_000

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: intervalNanoseconds)
            } catch {
                break
            }

            do {
                let result = try await gate.performWriteCommand(name: "indexRecent") { writer in
                    let scan = try await writer.indexRecentSessions()
                    // Run parent-link / dispatch detection on the freshly indexed
                    // sessions so agent children created mid-run are grouped under
                    // their parent (and skip-tiered) without waiting for a restart.
                    if scan.indexed > 0 {
                        try writer.runPeriodicParentBackfills()
                    }
                    // Drain any FTS jobs enqueued by this scan so search content
                    // is written (V1). Embedding jobs are marked not_applicable.
                    let jobSummary = try await IndexJobRunner(writer: writer).runRecoverableJobs()
                    let repoCandidates = try writer.read { db in
                        try RepoDiscovery.sessionCwdCounts(db)
                    }
                    return (scan: scan, jobs: jobSummary, repoCandidates: repoCandidates)
                }
                // Refresh git_repos from session cwds (replaces removed Node
                // git-probe.ts; populates the otherwise-dormant Repos page).
                // Git probes can be slow or wedged, so they run outside the
                // serialized service write gate; only the final upsert is gated.
                let repoEntries = RepoDiscovery.probeRepositories(result.value.repoCandidates)
                let repos = try await gate.performWriteCommand(name: "repoDiscoveryUpsert") { writer in
                    try writer.write { db in
                        try RepoDiscovery.upsert(
                            db,
                            entries: repoEntries,
                            probedAt: ISO8601DateFormatter().string(from: Date())
                        )
                    }
                }
                let scan = result.value.scan
                let jobs = result.value.jobs
                ServiceLogger.notice(
                    "index scan completed: indexed=\(scan.indexed) total=\(scan.total) todayParents=\(scan.todayParents) ftsCompleted=\(jobs.completed) ftsNotApplicable=\(jobs.notApplicable) repos=\(repos.value)",
                    category: .runner
                )
                emit(ServiceIndexEvent(
                    indexed: scan.indexed,
                    total: scan.total,
                    todayParents: scan.todayParents
                ))
                await statusMonitor.recordScanSuccess()
            } catch is CancellationError {
                break
            } catch {
                ServiceLogger.error("index scan failed", category: .runner, error: error)
                emit(ServiceIndexErrorEvent(error: error.localizedDescription))
                await statusMonitor.recordScanFailure(error.localizedDescription)
            }
        }
    }

    /// V2 composition root: runs the startup scan once, draining the FTS
    /// backlog. Builds real conformers over the unit-tested static funcs and
    /// runs through the gate so writes serialize with command dispatch.
    private static func runInitialScan(gate: ServiceWriterGate, statusMonitor: ServiceStatusMonitor) async {
        let startupAdapters = SessionAdapterFactory.recentActiveAdapters()
        let defaultAdapters = SessionAdapterFactory.defaultAdapters()
        let emitBackfill: (StartupBackfillEvent) -> Void = { event in
            Self.emit(StartupBackfillEventEnvelope(event: event))
        }
        do {
            // Phase 1 — structural backfills, split into THREE gated write
            // commands so the single write gate is RELEASED between them and
            // user write commands (project move, save_insight, manual link) can
            // interleave instead of waiting out the whole multi-minute scan. The
            // heavy re-index and the per-row orphan scan previously held the gate
            // for the entire run, so any user write queued in that window timed
            // out with WriterBusy.
            let indexed = try await gate.performWriteCommand(name: "initialScanIndex") { writer in
                try await StartupBackfills.runStartupIndex(
                    indexer: WriterStartupIndexing(writer: writer, adapters: startupAdapters)
                )
            }.value
            _ = try await gate.performWriteCommand(name: "initialScanBackfills") { writer in
                try await StartupBackfills.runStartupMaintenanceAndParents(
                    indexed: indexed,
                    emit: emitBackfill,
                    log: OSLogStartupBackfillLogging(),
                    indexer: WriterStartupIndexing(writer: writer, adapters: startupAdapters),
                    database: WriterStartupBackfillDatabase(writer: writer)
                )
            }
            _ = try await gate.performWriteCommand(name: "initialScanOrphans") { writer in
                try await StartupBackfills.runStartupOrphanScan(
                    emit: emitBackfill,
                    log: OSLogStartupBackfillLogging(),
                    orphanScanner: WriterStartupOrphanScanning(writer: writer),
                    database: WriterStartupBackfillDatabase(writer: writer),
                    adapters: startupAdapters
                )
            }

            // Phase 2 — drain the FTS backlog one batch per gated command, so a
            // large (100k+) drain releases the single write gate BETWEEN batches
            // and user write commands can interleave instead of failing with
            // WriterBusy after the gate is held for the whole scan.
            while !Task.isCancelled {
                let drained = try await gate.performWriteCommand(name: "initialFtsDrain") { writer in
                    try await IndexJobRunner(writer: writer, adapters: defaultAdapters)
                        .runRecoverableJobsOnce()
                        .drained
                }
                if drained.value { break }
            }

            // Phase 3 — start the usage collector (cheap); its own gated command.
            _ = try await gate.performWriteCommand(name: "initialUsage") { writer in
                WriterStartupUsageCollector(
                    writer: writer,
                    emit: { snapshots in Self.emit(ServiceUsageEvent(snapshots: snapshots)) }
                ).start()
            }

            ServiceLogger.notice("initial startup scan complete", category: .runner)
            await statusMonitor.recordScanSuccess()
        } catch is CancellationError {
            return
        } catch {
            ServiceLogger.error("initial startup scan failed", category: .runner, error: error)
            emit(ServiceIndexErrorEvent(error: error.localizedDescription))
            await statusMonitor.recordScanFailure(error.localizedDescription)
        }
    }

    private static func waitForWebHealth(host: String, port: Int) async throws {
        let url = URL(string: "http://\(host):\(port)/health")!
        for _ in 0..<100 {
            try Task.checkCancellation()
            if await webHealthResponds(url: url) {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw WebReadinessError.timeout(host: host, port: port)
    }

    private static func webHealthResponds(url: URL) async -> Bool {
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    private static let stdoutLock = NSLock()

    /// Serialize every structured-JSON line written to stdout. Multiple startup
    /// tasks (initial scan, indexing loop, checkpoint, web-ready) emit events
    /// concurrently; without a lock their `print()` + `fflush` can interleave or
    /// drop partial lines on the shared stdout stream.
    private static func writeStdoutLine(_ text: String) {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        print(text)
        fflush(stdout)
    }

    private static func emitWebReady(host: String, port: Int) {
        writeStdoutLine(#"{"event":"web_ready","host":"\#(host)","port":\#(port)}"#)
    }

    private static func emit<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        writeStdoutLine(text)
    }

    // MARK: - Web UI gating (SEC-C1)

    /// Reads the opt-in `webUIEnabled` flag. Default FALSE. An env override
    /// (`ENGRAM_WEB_UI_ENABLED=1`) is honored for tests/dev; otherwise the value
    /// comes from `~/.engram/settings.json`.
    static func readWebUIEnabled(environment: [String: String]) -> Bool {
        if let envValue = environment["ENGRAM_WEB_UI_ENABLED"] {
            return ["1", "true", "yes"].contains(envValue.lowercased())
        }
        let settingsURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        if let value = object["webUIEnabled"] as? Bool {
            return value
        }
        return false
    }

    /// Generates a per-launch bearer token and writes it to
    /// `<runtimeDirectory>/webui.token` with mode 0600. Returns nil on failure
    /// (the web UI then refuses to start, failing closed).
    static func provisionWebToken(runtimeDirectory: URL) -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let tokenURL = runtimeDirectory.appendingPathComponent("webui.token")
        do {
            try token.data(using: .utf8)?.write(to: tokenURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
            return token
        } catch {
            ServiceLogger.warn("failed to write web ui token: \(error.localizedDescription)", category: .runner)
            return nil
        }
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

private enum WebReadinessError: LocalizedError {
    case timeout(host: String, port: Int)

    var errorDescription: String? {
        switch self {
        case .timeout(let host, let port):
            return "Timed out waiting for Web UI at \(host):\(port)"
        }
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

private struct ServiceUsageEvent: Encodable {
    struct Item: Encodable {
        let source: String
        let metric: String
        let value: Double
        let status: String?
    }

    let event = "usage"
    let usage: [Item]

    init(snapshots: [StartupUsageSnapshot]) {
        self.usage = snapshots.map {
            Item(source: $0.source, metric: $0.metric, value: $0.value, status: $0.status)
        }
    }
}

private struct ServiceWebErrorEvent: Encodable {
    let event = "web_error"
    let message: String
}
