import Foundation

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
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            readProvider: try SQLiteEngramServiceReadProvider(databasePath: databasePath)
        )
        let server = UnixSocketServiceServer(socketPath: socketPath) { request in
            await handler.handle(request)
        }
        try server.start()
        let webTask = Task {
            do {
                let webServer = try EngramWebUIServer(databasePath: databasePath)
                print(#"{"event":"web_ready","host":"127.0.0.1","port":3457}"#)
                fflush(stdout)
                try await webServer.run()
            } catch is CancellationError {
                return
            } catch {
                ServiceLogger.warn(
                    "web ui failed to start: \(error.localizedDescription)",
                    category: .runner
                )
                print(#"{"event":"web_error","message":"\#(error.localizedDescription)"}"#)
                fflush(stdout)
            }
        }

        ServiceLogger.notice("service ready, listening on \(socketBasename)", category: .runner)
        print(#"{"event":"ready","socket":"\#(socketPath)"}"#)
        fflush(stdout)

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

        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // Wait for the startup truncate to finish before tearing down the gate.
        // SQLite's PRAGMA call doesn't observe Task cancellation, so the value
        // wait is what guarantees we don't drop the writer mid-checkpoint.
        // Bound by busy_timeout (30s) in the worst case; in practice <1s.
        await truncateTask.value
        indexingTask.cancel()
        checkpointTask.cancel()
        webTask.cancel()
        server.stop()
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
                    try await writer.indexRecentSessions()
                }
                ServiceLogger.notice(
                    "index scan completed: indexed=\(result.value.indexed) total=\(result.value.total) todayParents=\(result.value.todayParents)",
                    category: .runner
                )
                emit(ServiceIndexEvent(
                    indexed: result.value.indexed,
                    total: result.value.total,
                    todayParents: result.value.todayParents
                ))
            } catch is CancellationError {
                break
            } catch {
                ServiceLogger.error("index scan failed", category: .runner, error: error)
                emit(ServiceIndexErrorEvent(error: error.localizedDescription))
            }
        }
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
