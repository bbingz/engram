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
            print(#"{"event":"fatal","stage":"migrate","error":"\#(error.localizedDescription)"}"#)
            fflush(stdout)
            exit(70) // EX_SOFTWARE
        }

        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            readProvider: try SQLiteEngramServiceReadProvider(databasePath: databasePath)
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
        print(#"{"event":"ready","socket":"\#(socketPath)"}"#)
        fflush(stdout)

        // V2: run startup maintenance once, detached so it does not block the
        // health probe / ready emission. Runs through the gate so writes are
        // serialized with incoming commands. This also drains the FTS backlog
        // (via IndexJobRunner) so search content is actually written.
        let initialScanTask = Task {
            await Self.runInitialScan(gate: gate)
        }

        let indexingTask = Task {
            await Self.runIndexingLoop(gate: gate)
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
                    print(#"{"event":"checkpoint","mode":"PASSIVE","ok":true}"#)
                    fflush(stdout)
                } catch {
                    ServiceLogger.error(
                        "wal checkpoint failed (mode=PASSIVE)",
                        category: .checkpoint,
                        error: error
                    )
                    print(#"{"event":"checkpoint","mode":"PASSIVE","ok":false,"error":"\#(error.localizedDescription)"}"#)
                    fflush(stdout)
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

    private static func runIndexingLoop(gate: ServiceWriterGate) async {
        let intervalNanoseconds: UInt64 = 5 * 60 * 1_000_000_000
        var isFirstScan = true

        while !Task.isCancelled {
            if isFirstScan {
                isFirstScan = false
            } else {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    break
                }
            }

            do {
                let result = try await gate.performWriteCommand(name: "indexRecent") { writer in
                    let scan = try await writer.indexRecentSessions()
                    // Drain any FTS jobs enqueued by this scan so search content
                    // is written (V1). Embedding jobs are marked not_applicable.
                    let jobSummary = try await IndexJobRunner(writer: writer).runRecoverableJobs()
                    // Refresh git_repos from session cwds (replaces removed Node
                    // git-probe.ts; populates the otherwise-dormant Repos page).
                    let repos = try writer.write { db in try RepoDiscovery.discover(db) }
                    return (scan: scan, jobs: jobSummary, repos: repos)
                }
                let scan = result.value.scan
                let jobs = result.value.jobs
                ServiceLogger.notice(
                    "index scan completed: indexed=\(scan.indexed) total=\(scan.total) todayParents=\(scan.todayParents) ftsCompleted=\(jobs.completed) ftsNotApplicable=\(jobs.notApplicable) repos=\(result.value.repos)",
                    category: .runner
                )
                emit(ServiceIndexEvent(
                    indexed: scan.indexed,
                    total: scan.total,
                    todayParents: scan.todayParents
                ))
            } catch is CancellationError {
                break
            } catch {
                ServiceLogger.error("index scan failed", category: .runner, error: error)
                emit(ServiceIndexErrorEvent(error: error.localizedDescription))
            }
        }
    }

    /// V2 composition root: runs the startup scan once, draining the FTS
    /// backlog. Builds real conformers over the unit-tested static funcs and
    /// runs through the gate so writes serialize with command dispatch.
    private static func runInitialScan(gate: ServiceWriterGate) async {
        do {
                _ = try await gate.performWriteCommand(name: "initialScan") { writer in
                let startupAdapters = SessionAdapterFactory.recentActiveAdapters()
                let jobRunner = IndexJobRunner(writer: writer, adapters: SessionAdapterFactory.defaultAdapters())
                try await StartupBackfills.runInitialScan(
                    emit: { event in Self.emit(StartupBackfillEventEnvelope(event: event)) },
                    log: OSLogStartupBackfillLogging(),
                    usageCollector: NoopStartupUsageCollector(),
                    indexer: WriterStartupIndexing(writer: writer, adapters: startupAdapters),
                    indexJobRunner: jobRunner,
                    database: WriterStartupBackfillDatabase(writer: writer),
                    orphanScanner: WriterStartupOrphanScanning(writer: writer),
                    adapters: startupAdapters
                )
            }
            ServiceLogger.notice("initial startup scan complete", category: .runner)
        } catch is CancellationError {
            return
        } catch {
            ServiceLogger.error("initial startup scan failed", category: .runner, error: error)
            emit(ServiceIndexErrorEvent(error: error.localizedDescription))
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

    private static func emitWebReady(host: String, port: Int) {
        print(#"{"event":"web_ready","host":"\#(host)","port":\#(port)}"#)
        fflush(stdout)
    }

    private static func emit<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        print(text)
        fflush(stdout)
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

private struct ServiceWebErrorEvent: Encodable {
    let event = "web_error"
    let message: String
}
