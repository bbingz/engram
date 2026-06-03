import XCTest
import GRDB
import Darwin
import Foundation
@testable import EngramServiceCore

final class EngramServiceIPCTests: XCTestCase {
    func testReadAIContextAggregatesAllFtsRows() throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, model, message_count,
                  user_message_count, assistant_message_count, file_path, size_bytes, indexed_at
                ) VALUES (
                  'multi', 'codex', '2026-04-23T06:00:00Z', '/tmp/engram', 'engram',
                  'gpt-5.4', 3, 2, 1, '/tmp/multi.jsonl', 45, '2026-04-23T06:00:00Z'
                );
                INSERT INTO sessions_fts(session_id, content) VALUES ('multi', 'first message');
                INSERT INTO sessions_fts(session_id, content) VALUES ('multi', 'second message');
                INSERT INTO sessions_fts(session_id, content) VALUES ('multi', 'third message');
                """
            )
        }

        let context = try EngramServiceCommandHandler.readAIContext(
            sessionId: "multi",
            databasePath: paths.database.path
        )

        XCTAssertTrue(context.transcript.contains("first message"))
        XCTAssertTrue(context.transcript.contains("second message"))
        XCTAssertTrue(context.transcript.contains("third message"))
    }

    func testReadTitleContextsExcludesSkipTierAndTitledSessions() throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, model, message_count,
                  user_message_count, assistant_message_count, file_path, size_bytes, indexed_at, tier
                ) VALUES (
                  'skip-untitled', 'codex', '2026-04-23T05:00:00Z', '/tmp/engram', 'engram',
                  'gpt-5.4', 2, 1, 1, '/tmp/skip.jsonl', 44, '2026-04-23T05:00:00Z', 'skip'
                );
                """
            )
        }

        let ids = try EngramServiceCommandHandler
            .readTitleContexts(databasePath: paths.database.path)
            .map(\.id)

        XCTAssertTrue(ids.contains("s2"), "untitled normal-tier session should be included")
        XCTAssertFalse(ids.contains("skip-untitled"), "skip-tier session must be excluded")
        XCTAssertFalse(ids.contains("s1"), "already-titled session must be excluded")
    }

    func testGenerateTitlesForContextsHonorsCancellationBeforeWork() async throws {
        let contexts = [
            EngramServiceCommandHandler.AIContext(
                id: "s1",
                source: "codex",
                project: "engram",
                cwd: "/tmp/engram",
                messageCount: 1,
                startTime: "2026-04-23T00:00:00Z",
                nativeTitle: "Native title",
                nativeSummary: "Summary",
                transcript: "hello"
            )
        ]

        let task = Task {
            try await EngramServiceCommandHandler.generateTitlesForContexts(
                contexts: contexts,
                titleConfig: nil
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled title regeneration must not continue to produce updates")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testGenerateTitlesForContextsReportsProgressAfterEachTitle() async throws {
        let contexts = (1...3).map { index in
            EngramServiceCommandHandler.AIContext(
                id: "s\(index)",
                source: "codex",
                project: "engram",
                cwd: "/tmp/engram",
                messageCount: 1,
                startTime: "2026-04-23T00:00:0\(index)Z",
                nativeTitle: "Native \(index)",
                nativeSummary: "Summary \(index)",
                transcript: "hello \(index)"
            )
        }
        var progress: [(Int, Int)] = []

        let generated = try await EngramServiceCommandHandler.generateTitlesForContexts(
            contexts: contexts,
            titleConfig: nil,
            progress: { completed, total in
                progress.append((completed, total))
            }
        )

        XCTAssertEqual(generated.map(\.id), ["s1", "s2", "s3"])
        XCTAssertEqual(generated.map(\.title), ["Native 1", "Native 2", "Native 3"])
        XCTAssertEqual(progress.map { "\($0.0)/\($0.1)" }, ["1/3", "2/3", "3/3"])
    }

    func testGenerateTitlesForContextsCapsAIConcurrency() async throws {
        let contexts = (1...12).map { index in
            EngramServiceCommandHandler.AIContext(
                id: "s\(index)",
                source: "codex",
                project: "engram",
                cwd: "/tmp/engram",
                messageCount: 1,
                startTime: "2026-04-23T00:00:0\(index % 10)Z",
                nativeTitle: "Native \(index)",
                nativeSummary: "Summary \(index)",
                transcript: "hello \(index)"
            )
        }
        let config = EngramServiceCommandHandler.ServiceAISettings.ChatConfig(
            provider: "test",
            baseURL: "http://127.0.0.1",
            apiKey: "test",
            model: "title-test",
            maxTokens: 16,
            temperature: 0
        )
        let probe = TitleConcurrencyProbe()

        let generated = try await EngramServiceCommandHandler.generateTitlesForContexts(
            contexts: contexts,
            titleConfig: config,
            maxConcurrency: 4,
            titleProvider: { context, _ in
                await probe.enter()
                try await Task.sleep(nanoseconds: 20_000_000)
                await probe.leave()
                return "Generated \(context.id)"
            }
        )

        XCTAssertEqual(generated.count, contexts.count)
        let peak = await probe.maximum()
        XCTAssertLessThanOrEqual(peak, 4)
    }

    func testRenderSummaryPromptHonorsLanguageMaxSentencesAndStyle() throws {
        let prompt = EngramServiceCommandHandler.ServiceAIClient.renderSummaryPrompt(
            language: "English",
            maxSentences: 5,
            style: "bullet points",
            template: ""
        )

        XCTAssertTrue(prompt.contains("English"))
        XCTAssertTrue(prompt.contains("5"))
        XCTAssertTrue(prompt.contains("风格要求：bullet points"))
        XCTAssertFalse(prompt.contains("{{"), "all placeholders must be substituted")
    }

    func testServiceAISettingsSummaryConfigCarriesTuning() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-ai-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        try """
        {
          "aiProtocol": "openai",
          "aiApiKey": "@keychain",
          "aiModel": "gpt-4o-mini",
          "summaryLanguage": "English",
          "summaryMaxSentences": 5,
          "summaryStyle": "bullet points"
        }
        """.data(using: .utf8)!.write(to: settingsURL)

        let settings = EngramServiceCommandHandler.ServiceAISettings.read(
            settingsPath: settingsURL,
            environment: ["ENGRAM_KEYCHAIN_aiApiKey": "secret"]
        )

        XCTAssertEqual(settings.summaryConfig?.summaryLanguage, "English")
        XCTAssertEqual(settings.summaryConfig?.summaryMaxSentences, 5)
        XCTAssertEqual(settings.summaryConfig?.summaryStyle, "bullet points")
    }

    func testAIChatURLDoesNotDoubleV1Path() throws {
        let url = try EngramServiceCommandHandler.ServiceAIClient.chatCompletionsURL(
            baseURL: "https://token-plan-sgp.xiaomimimo.com/v1"
        )
        XCTAssertEqual(url.absoluteString, "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions")
    }

    func testServiceAISettingsReadsLegacySwiftTitleBaseURLAndKeychainEnv() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-ai-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        try """
        {
          "titleProvider": "custom",
          "titleBaseURL": "https://token-plan-sgp.xiaomimimo.com",
          "titleApiKey": "@keychain",
          "titleModel": "mimo-2.5-pro"
        }
        """.data(using: .utf8)!.write(to: settingsURL)

        let settings = EngramServiceCommandHandler.ServiceAISettings.read(
            settingsPath: settingsURL,
            environment: ["ENGRAM_KEYCHAIN_titleApiKey": "secret"]
        )

        XCTAssertEqual(settings.titleConfig?.baseURL, "https://token-plan-sgp.xiaomimimo.com")
        XCTAssertEqual(settings.titleConfig?.apiKey, "secret")
        XCTAssertEqual(settings.titleConfig?.model, "mimo-v2.5-pro")
        XCTAssertEqual(settings.titleConfig?.maxTokens, 120)
    }

    func testServiceAIClientLogsLLMRequestLifecycle() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceCommandHandler.swift")

        XCTAssertTrue(source.contains("LLM request started purpose="))
        XCTAssertTrue(source.contains("LLM request succeeded purpose="))
        XCTAssertTrue(source.contains("LLM request failed purpose="))
        XCTAssertTrue(source.contains("durationMs="))
        XCTAssertTrue(source.contains("status="))
        XCTAssertTrue(source.contains("reason=empty-content"))
        XCTAssertTrue(source.contains("\"max_completion_tokens\""))
        XCTAssertTrue(source.contains("\"thinking\""))
        XCTAssertTrue(source.contains("ServiceLogger.notice("))
    }

    func testLLMErrorEnvelopeDoesNotEchoUpstreamBody() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceCommandHandler.swift")

        XCTAssertTrue(source.contains("AI request failed with status \\(status)"))
        XCTAssertFalse(
            source.contains("body.prefix"),
            "LLM upstream response body must not be echoed into the IPC error envelope or logs"
        )
    }

    func testConfirmSuggestionUpdatesLinkCheckedAt() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceCommandHandler.swift")
        let start = try XCTUnwrap(source.range(of: "private static func confirmSuggestion"))
        let end = try XCTUnwrap(source.range(of: "private static func setParentSession"))
        let confirmSource = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(
            confirmSource.contains("link_checked_at = datetime('now')"),
            "confirmSuggestion must mirror setParentSession and mark the manual link as checked"
        )
    }

    func testProjectMigrationCommandsEmitServiceLogs() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceCommandHandler+ProjectMigration.swift")

        for command in ["projectMove", "projectArchive", "projectUndo", "projectMoveBatch"] {
            XCTAssertTrue(source.contains("\"\(command) requested"), "\(command) must log entry")
            XCTAssertTrue(source.contains("\"\(command) finished"), "\(command) must log success")
            XCTAssertTrue(source.contains("\"\(command) failed"), "\(command) must log failure")
        }
        XCTAssertTrue(source.contains("ServiceLogger.notice("))
        XCTAssertTrue(source.contains("ServiceLogger.error("))
    }

    func testRunnerStartupScanUsesRecentActiveAdapters() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")

        XCTAssertTrue(source.contains("let startupAdapters = SessionAdapterFactory.recentActiveAdapters()"))
        XCTAssertTrue(source.contains("indexer: WriterStartupIndexing(writer: writer, adapters: startupAdapters)"))
        XCTAssertTrue(source.contains("adapters: startupAdapters"))
    }

    func testRunnerRepoDiscoveryProbesOutsideWriteGate() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")

        XCTAssertTrue(source.contains("RepoDiscovery.sessionCwdCounts"))
        XCTAssertTrue(source.contains("RepoDiscovery.probeRepositories"))
        XCTAssertTrue(source.contains("RepoDiscovery.upsert"))
        XCTAssertFalse(source.contains("writer.write { db in try RepoDiscovery.discover(db) }"))
    }

    func testRunnerPeriodicScanDoesNotCompeteWithStartupScanImmediately() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")

        XCTAssertFalse(
            source.contains("var isFirstScan = true"),
            "Periodic indexing must not run an immediate first scan while startup maintenance already holds the write gate"
        )
        let sleepRange = try XCTUnwrap(source.range(of: "try await Task.sleep(nanoseconds: intervalNanoseconds)"))
        let writeRange = try XCTUnwrap(source.range(of: #"gate.performWriteCommand(name: "indexRecent")"#))
        XCTAssertLessThan(sleepRange.lowerBound, writeRange.lowerBound)
    }

    func testRunnerInitialScanSplitsWriteGateAcrossPhases() throws {
        // idx-2: the structural startup scan must NOT hold the single write gate
        // for the whole multi-minute run. It is split into separate gated write
        // commands (index | maintenance+parents | orphan scan) so user writes can
        // interleave between phases instead of timing out with WriterBusy.
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        XCTAssertFalse(
            source.contains(#"performWriteCommand(name: "initialScan")"#),
            "the whole structural scan must not run as one gated write command"
        )
        XCTAssertTrue(source.contains(#"performWriteCommand(name: "initialScanIndex")"#))
        XCTAssertTrue(source.contains(#"performWriteCommand(name: "initialScanBackfills")"#))
        XCTAssertTrue(source.contains(#"performWriteCommand(name: "initialScanOrphans")"#))
    }

    func testRunnerObservabilityRetentionLogsZeroRowCompletion() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let start = try XCTUnwrap(source.range(of: "private static func runObservabilityRetention"))
        let end = try XCTUnwrap(source.range(of: "private static func runIndexingLoop"))
        let retentionSource = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(
            retentionSource.contains("if total > 0"),
            "observability retention must log completion even when no rows are pruned"
        )
        XCTAssertTrue(retentionSource.contains("observability retention complete: pruned=\\(total)"))
    }

    func testRunnerPeriodicScanRunsParentBackfills() throws {
        // idx-1: the periodic indexRecent scan must run parent-link / dispatch
        // detection so agent children created mid-run are grouped under their
        // parent (and skip-tiered) without waiting for a service restart.
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        XCTAssertTrue(
            source.contains("runPeriodicParentBackfills"),
            "the periodic indexing loop must run parent backfills after indexing new sessions"
        )
    }

    func testProjectMigrationPipelineErrorTestUsesScopedHome() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "\n    func testProjectMigrationCommandsSurfacePipelineErrors"))
        let end = try XCTUnwrap(source.range(of: "\n    func testUnsupportedTriggerSyncDoesNotAdvanceDatabaseGeneration"))
        let testSource = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(testSource.contains("ServiceCoreTestHomeScope(home:"))
        XCTAssertFalse(
            testSource.contains("FileManager.default.homeDirectoryForCurrentUser"),
            "project migration pipeline error test must not create paths under the real HOME"
        )
    }

    func testUnixSocketServiceServerLifecycleUsesTrackedSendableState() throws {
        let source = try serviceCoreSource("EngramService/IPC/UnixSocketServiceServer.swift")

        XCTAssertFalse(
            source.contains("@unchecked Sendable"),
            "UnixSocketServiceServer must not hide lifecycle data races with @unchecked Sendable"
        )
        XCTAssertFalse(
            source.contains("private var fd"),
            "Socket file descriptor must be kept in synchronized lifecycle state"
        )
        XCTAssertFalse(
            source.contains("private var acceptTask"),
            "Accept task must be kept in synchronized lifecycle state"
        )
    }

    func testUnixSocketClientTransportUsesCheckedSendable() throws {
        let source = try serviceCoreSource("Shared/Service/UnixSocketEngramServiceTransport.swift")

        XCTAssertTrue(source.contains("final class UnixSocketEngramServiceTransport: EngramServiceTransport, Sendable"))
        XCTAssertFalse(
            source.contains("UnixSocketEngramServiceTransport: EngramServiceTransport, @unchecked Sendable"),
            "client transport only stores Sendable let values and must not use unchecked Sendable"
        )
        XCTAssertTrue(source.contains("private final class FdBox: @unchecked Sendable"))
    }

    func testServerRejectsClientWhenSocketTimeoutCannotBeArmed() throws {
        // ipc-3: setSocketTimeout is the only bound on the blocking readFrame, so
        // a failure must reject the connection (close + signal) rather than be
        // swallowed with try? and leak a connection-limiter permit.
        let source = try serviceCoreSource("EngramService/IPC/UnixSocketServiceServer.swift")
        XCTAssertFalse(
            source.contains("try? UnixSocketEngramServiceTransport.setSocketTimeout"),
            "setSocketTimeout failure must reject the connection, not be swallowed with try?"
        )
    }

    func testUnixSocketServiceServerOffloadsBlockingFrameIO() throws {
        // conc-1: per-client readFrame/writeFrame are POSIX blocking calls. They
        // must run on a dedicated GCD queue instead of occupying Swift cooperative
        // executor threads while a client is slow or idle.
        let source = try serviceCoreSource("EngramService/IPC/UnixSocketServiceServer.swift")
        XCTAssertTrue(source.contains("blockingIOQueue.async"))
        XCTAssertTrue(source.contains("readFrameOffCooperativePool"))
        XCTAssertTrue(source.contains("writeFrameOffCooperativePool"))
        XCTAssertFalse(
            source.contains("let frame = try UnixSocketEngramServiceTransport.readFrame(from: client)"),
            "client tasks must not call blocking readFrame directly"
        )
        XCTAssertFalse(
            source.contains("try UnixSocketEngramServiceTransport.writeFrame(try JSONEncoder().encode(response), to: client)"),
            "client tasks must not call blocking writeFrame directly"
        )
    }

    func testUnixSocketServiceServerStopCancelsInFlightClientHandlers() async throws {
        let paths = try makeServiceIPCPaths()
        let requestStarted = expectation(description: "request handler started")
        let handlerCancelled = expectation(description: "request handler cancelled")
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            requestStarted.fulfill()
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                XCTFail("server.stop() must cancel active client handlers")
            } catch is CancellationError {
                handlerCancelled.fulfill()
            } catch {
                XCTFail("unexpected handler error: \(error)")
            }
            return .failure(
                requestId: request.requestId,
                error: EngramServiceErrorEnvelope(
                    name: "Cancelled",
                    message: "Handler cancelled",
                    retryPolicy: "never"
                )
            )
        }
        try server.start()

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let requestTask = Task {
            _ = try? await client.status()
        }

        await fulfillment(of: [requestStarted], timeout: 1)
        server.stop()
        await fulfillment(of: [handlerCancelled], timeout: 1)
        requestTask.cancel()
    }

    func testStartGateRaceCleansUpClientFdAndPermitOnStop() throws {
        // lifecycle: if stop() flips the listener between accept() and
        // registration, the !shouldContinue branch must close(client) AND
        // signal the connection limiter directly — otherwise the parked client
        // task never runs its defer and the fd + connection-limiter permit leak
        // (32 leaks wedge ALL future connections). The start gate must also be
        // cancellation-aware so the parked task can be unwound.
        let source = try serviceCoreSource("EngramService/IPC/UnixSocketServiceServer.swift")
        XCTAssertTrue(
            source.contains("if !shouldContinue {"),
            "accept loop must branch on registration success"
        )
        // The cleanup (close + signal) must live in the !shouldContinue branch.
        guard let branchRange = source.range(of: "if !shouldContinue {") else {
            return XCTFail("missing !shouldContinue branch")
        }
        let branchTail = String(source[branchRange.lowerBound...].prefix(600))
        XCTAssertTrue(
            branchTail.contains("close(client)"),
            "!shouldContinue branch must close the orphaned client fd"
        )
        XCTAssertTrue(
            branchTail.contains("await connectionLimiter.signal()"),
            "!shouldContinue branch must release the connection-limiter permit"
        )
        XCTAssertTrue(
            source.contains("withTaskCancellationHandler"),
            "ClientTaskStartGate.wait() must be cancellation-aware so a parked task can be unwound"
        )
    }

    func testServerRecyclesPermitsAcrossManySequentialConnections() async throws {
        // lifecycle/behavioral: each completed request must return its
        // connection-limiter permit. Run well past the 32-permit cap
        // sequentially; if any permit leaked, accept() would wedge once 32 were
        // consumed and this would hang past the timeout.
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        for _ in 0..<64 {
            let client = EngramServiceClient(
                transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
            )
            _ = try await client.status()
        }
        XCTAssertEqual(server.activeClientTaskCountForTesting(), 0)
    }

    func testTransportTracksWholeFrameWallClockDeadline() throws {
        // perf: SO_RCVTIMEO/SO_SNDTIMEO only bound a single syscall, so a peer
        // trickling one byte before each window can stretch a frame across
        // maximumFrameLength iterations. The transport must additionally track a
        // wall-clock deadline for the whole frame.
        let source = try serviceCoreSource("Shared/Service/UnixSocketEngramServiceTransport.swift")
        XCTAssertTrue(
            source.contains("maximumFrameDurationSeconds"),
            "transport must define a whole-frame wall-clock budget"
        )
        XCTAssertTrue(
            source.contains("checkFrameDeadline"),
            "readExact/writeAll must check the per-frame deadline before each blocking syscall"
        )
        XCTAssertTrue(
            source.contains("deadline: Date?"),
            "the per-frame deadline must be threaded into readExact/writeAll"
        )
    }

    func testTransportRetriesInterruptedReadWriteSyscalls() throws {
        let source = try serviceCoreSource("Shared/Service/UnixSocketEngramServiceTransport.swift")

        XCTAssertTrue(source.contains("errno == EINTR"))
        XCTAssertTrue(source.contains("continue"))
    }

    func testServiceReadsHopOffCooperativePool() throws {
        // concurrency: synchronous pool.read for big FTS/LIKE scans must not run
        // on a Swift cooperative-executor thread, or a single scan can starve
        // every other concurrent service request. The blocking read must hop to
        // a dedicated GCD queue.
        let source = try serviceCoreSource("EngramService/Core/EngramServiceReadProvider.swift")
        XCTAssertTrue(
            source.contains("blockingReadQueue"),
            "read provider must offload blocking GRDB reads onto a dedicated queue"
        )
        XCTAssertTrue(
            source.contains("blockingReadQueue.async"),
            "blocking reads must run on the dedicated queue, not the cooperative pool"
        )
        XCTAssertFalse(
            source.contains("try databaseReader.read(block)\n    }"),
            "the read helper must not call the synchronous reader directly from the cooperative pool"
        )
    }

    func testServiceLogCategoriesHaveProductionCallsites() throws {
        let ipcSource = try serviceCoreSource("EngramService/IPC/UnixSocketServiceServer.swift")
        let readerSource = try serviceCoreSource("EngramService/Core/EngramServiceReadProvider.swift")

        XCTAssertTrue(
            ipcSource.contains("category: .ipc"),
            "the IPC service log category must have a real production callsite"
        )
        XCTAssertTrue(
            readerSource.contains("category: .reader"),
            "the reader service log category must have a real production callsite"
        )
    }

    func testSearchServesConcurrentRequestsWithoutDeadlock() async throws {
        // concurrency/behavioral: the offloaded read must still return correct
        // results when many search requests run concurrently.
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        try await withThrowingTaskGroup(of: [String].self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await provider.search(
                        EngramServiceSearchRequest(query: "hello", mode: "keyword", limit: 10)
                    ).items.map(\.id)
                }
            }
            for try await ids in group {
                XCTAssertEqual(ids, ["s1"])
            }
        }
    }

    func testConcurrentWriteIntentsSerializeThroughOneServiceGate() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)

        async let first = handler.handle(EngramServiceRequestEnvelope(command: "test.write_intent"))
        async let second = handler.handle(EngramServiceRequestEnvelope(command: "test.write_intent"))

        let generations = try await [writeIntentGeneration(from: first), writeIntentGeneration(from: second)].sorted()
        XCTAssertEqual(generations, [1, 2])
    }

    func testStatusCommandUsesProductionSocketTransport() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let status = try await client.status()
        XCTAssertEqual(status, .running(total: 0, todayParents: 0))
    }

    func testStatusCommandReportsDegradedAfterIndexFailure() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let monitor = ServiceStatusMonitor(staleAfter: 600)
        await monitor.recordScanFailure("adapter exploded", at: Date(timeIntervalSince1970: 100))
        let handler = EngramServiceCommandHandler(writerGate: gate, statusMonitor: monitor)

        let response = await handler.handle(EngramServiceRequestEnvelope(command: "status"))
        guard case .success(_, let data, _) = response else {
            return XCTFail("status should succeed")
        }

        let status = try JSONDecoder().decode(EngramServiceStatus.self, from: data)
        XCTAssertEqual(status, .degraded(message: "Last index scan failed: adapter exploded"))
    }

    func testStatusCommandReportsDegradedWhenLastSuccessfulScanIsStale() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let monitor = ServiceStatusMonitor(staleAfter: 600, now: { Date(timeIntervalSince1970: 1_001) })
        await monitor.recordScanSuccess(at: Date(timeIntervalSince1970: 100))
        let handler = EngramServiceCommandHandler(writerGate: gate, statusMonitor: monitor)

        let response = await handler.handle(EngramServiceRequestEnvelope(command: "status"))
        guard case .success(_, let data, _) = response else {
            return XCTFail("status should succeed")
        }

        let status = try JSONDecoder().decode(EngramServiceStatus.self, from: data)
        XCTAssertEqual(status, .degraded(message: "Last successful index scan is stale (901s old)"))
    }

    func testRunnerCancellationReleasesWriterGateAndRemovesSocket() async throws {
        let paths = try makeServiceIPCPaths()

        let runner = Task {
            try await EngramServiceRunner.run(
                arguments: [
                    "--service-socket", paths.socket.path,
                    "--database-path", paths.database.path
                ],
                environment: [:]
            )
        }
        try await waitUntilFileExists(paths.socket.path)

        runner.cancel()
        do {
            try await runner.value
        } catch is CancellationError {
            // Also acceptable: the important contract is cleanup.
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socket.path))
        XCTAssertNoThrow(
            try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime),
            "runner cancellation must release process and database writer locks"
        )
    }

    func testReadOnlyAppFacingCommandsDoNotReturnUnsupportedCommand() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))

        let health = try await client.health()
        let live = try await client.liveSessions()
        let sources = try await client.sources()
        let skills = try await client.skills()
        let memory = try await client.memoryFiles()
        let hooks = try await client.hooks()
        let replay = try await client.replayTimeline(sessionId: "session-1", limit: 25)
        let embedding = try await client.embeddingStatus()

        XCTAssertEqual(health.status, "healthy")
        XCTAssertEqual(live.count, 0)
        XCTAssertEqual(sources, [])
        XCTAssertEqual(skills, [])
        XCTAssertEqual(memory, [])
        XCTAssertEqual(hooks, [])
        XCTAssertEqual(replay.sessionId, "session-1")
        XCTAssertFalse(embedding.available)
    }

    func testSQLiteReadProviderServesSearchSourcesAndEmbeddingStatus() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            readProvider: try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)
        )
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))

        let search = try await client.search(EngramServiceSearchRequest(query: "hello", mode: "keyword", limit: 10))
        XCTAssertEqual(search.items.map(\.id), ["s1"])
        XCTAssertEqual(search.items.first?.generatedTitle, "Generated Title")
        XCTAssertEqual(search.items.first?.source, "codex")
        XCTAssertEqual(search.searchModes, ["keyword"])

        let sources = try await client.sources()
        XCTAssertEqual(sources, [
            EngramServiceSourceInfo(name: "codex", sessionCount: 2, latestIndexed: "2026-04-23T02:00:00Z")
        ])

        let embedding = try await client.embeddingStatus()
        XCTAssertTrue(embedding.available)
        XCTAssertEqual(embedding.embeddedCount, 1)
        XCTAssertEqual(embedding.totalSessions, 2)
        XCTAssertEqual(embedding.progress, 50)
    }

    func testSearchSemanticModeDegradesToKeywordWithWarning() async throws {
        // R5-56: the service search path is keyword-only. A semantic/hybrid
        // request must not be silently ignored — it degrades to keyword and
        // surfaces a warning so callers know semantic results were skipped.
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let semantic = try await provider.search(
            EngramServiceSearchRequest(query: "hello", mode: "semantic", limit: 10)
        )
        XCTAssertEqual(semantic.items.map(\.id), ["s1"])
        XCTAssertEqual(semantic.searchModes, ["keyword"])
        XCTAssertNotNil(semantic.warning)

        let hybrid = try await provider.search(
            EngramServiceSearchRequest(query: "hello", mode: "hybrid", limit: 10)
        )
        XCTAssertNotNil(hybrid.warning)

        // Keyword mode stays warning-free.
        let keyword = try await provider.search(
            EngramServiceSearchRequest(query: "hello", mode: "keyword", limit: 10)
        )
        XCTAssertNil(keyword.warning)
    }

    func testFtsMetacharacterQueryIsEscapedNotASyntaxError() async throws {
        // Audit round 1 (#19): a query containing FTS5 metacharacters (here an
        // unbalanced double-quote) must NOT reach SQLite as a raw MATCH and fail
        // with a syntax error. ftsMatchQuery quotes each token, so the query is
        // treated as a literal search and returns gracefully. (The never-retry
        // tagging of genuine syntax errors is still locked by
        // testSyntaxErrorEnvelopeClassification below.)
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            readProvider: try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)
        )

        // Unbalanced double-quote would be a raw fts5 syntax error; escaping
        // must turn it into a safe literal query instead.
        let request = EngramServiceRequestEnvelope(
            command: "search",
            payload: try JSONEncoder().encode(
                EngramServiceSearchRequest(query: "\"unterminated", mode: "keyword", limit: 10)
            )
        )
        let response = await handler.handle(request)
        guard case .success = response else {
            return XCTFail("escaped FTS metacharacter query must succeed, got \(response)")
        }
    }

    func testSyntaxErrorEnvelopeClassification() {
        // Direct unit coverage for the classifier so the policy is locked even
        // if the IPC plumbing changes.
        let syntax = DatabaseError(resultCode: .SQLITE_ERROR, message: "fts5: syntax error near \"\"")
        XCTAssertTrue(EngramServiceCommandHandler.isSyntaxError(syntax))
        XCTAssertEqual(EngramServiceCommandHandler.genericErrorEnvelope(syntax).retryPolicy, "never")

        let transient = DatabaseError(resultCode: .SQLITE_BUSY, message: "database is locked")
        XCTAssertFalse(EngramServiceCommandHandler.isSyntaxError(transient))
        XCTAssertEqual(EngramServiceCommandHandler.genericErrorEnvelope(transient).retryPolicy, "safe")
    }

    func testSQLiteReadProviderSearchExcludesSkipAndLiteSessions() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, model, message_count,
                  user_message_count, assistant_message_count, file_path, size_bytes,
                  indexed_at, tier
                ) VALUES
                  ('s-skip', 'codex', '2026-04-23T03:00:00Z', '/tmp/engram', 'engram', 'gpt-5.4', 2, 1, 1, '/tmp/skip.jsonl', 44, '2026-04-23T03:00:00Z', 'skip'),
                  ('s-lite', 'codex', '2026-04-23T04:00:00Z', '/tmp/engram', 'engram', 'gpt-5.4', 2, 1, 1, '/tmp/lite.jsonl', 45, '2026-04-23T04:00:00Z', 'lite');
                INSERT INTO sessions_fts(session_id, content) VALUES ('s-skip', 'hello from skipped noise');
                INSERT INTO sessions_fts(session_id, content) VALUES ('s-lite', 'hello from lite noise');
                """
            )
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let search = try await provider.search(EngramServiceSearchRequest(query: "hello", mode: "keyword", limit: 10))

        XCTAssertEqual(search.items.map(\.id), ["s1"])
    }

    // Latin/MATCH search must return a match-centered, highlighted snippet
    // (FTS5 snippet()) rather than the transcript from char 0, so humans get the
    // same windowed result the MCP/AI path already produces. Regression guard:
    // snippet() is invalid alongside GROUP BY, so it runs in a correlated
    // subquery; a naive `snippet(...) ... GROUP BY` throws at query time.
    func testSQLiteReadProviderSearchReturnsHighlightedWindowedSnippet() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        // Push the match far from the start so a whole-content snippet would show
        // only leading filler; a windowed snippet surfaces the matched term.
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 200)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions_fts SET content = ? WHERE session_id = 's1'",
                arguments: ["\(filler) needle \(filler)"]
            )
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let search = try await provider.search(
            EngramServiceSearchRequest(query: "needle", mode: "keyword", limit: 10)
        )

        XCTAssertEqual(search.items.map(\.id), ["s1"])
        let snippet = try XCTUnwrap(search.items.first?.snippet)
        XCTAssertTrue(
            snippet.contains("<mark>needle</mark>"),
            "expected highlighted match, got: \(snippet.prefix(120))"
        )
        XCTAssertLessThan(
            snippet.count, filler.count,
            "snippet must be a match-centered window, not the full content"
        )
    }

    // CJK search uses LIKE (FTS5 trigram MATCH is unreliable for CJK), so FTS5
    // snippet() can't run; the windowed `<mark>` highlight is built in Swift
    // (cjkHighlightedSnippet). Without it CJK users got the transcript from
    // char 0 with no highlight — the "AI can search, humans can't" gap for
    // Chinese projects.
    func testSQLiteReadProviderCJKSearchReturnsHighlightedWindowedSnippet() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        // 800-char CJK filler with the needle buried in the middle, so a
        // whole-content snippet would show only leading filler.
        let filler = String(repeating: "你好世界这是填充内容", count: 80)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions_fts SET content = ? WHERE session_id = 's1'",
                arguments: ["\(filler)需要修复这个缺陷\(filler)"]
            )
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let search = try await provider.search(
            EngramServiceSearchRequest(query: "需要修复", mode: "keyword", limit: 10)
        )

        XCTAssertEqual(search.items.map(\.id), ["s1"])
        let snippet = try XCTUnwrap(search.items.first?.snippet)
        XCTAssertTrue(
            snippet.contains("<mark>需要修复</mark>"),
            "expected highlighted CJK match, got: \(snippet.prefix(80))"
        )
        XCTAssertLessThan(
            snippet.count, filler.count,
            "snippet must be a match-centered window, not the full content"
        )
    }

    func testSQLiteReadProviderSearchAppliesProjectSourceAndSinceFilters() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, model, message_count,
                  user_message_count, assistant_message_count, file_path, size_bytes,
                  indexed_at
                ) VALUES
                  ('wrong-project', 'codex', '2026-05-20T10:00:00Z', '/tmp/other', 'other', 'gpt-5.4', 2, 1, 1, '/tmp/wrong-project.jsonl', 46, '2026-05-20T10:00:00Z'),
                  ('wrong-source', 'claude-code', '2026-05-20T10:00:00Z', '/tmp/engram', 'engram', 'sonnet', 2, 1, 1, '/tmp/wrong-source.jsonl', 47, '2026-05-20T10:00:00Z'),
                  ('too-old', 'codex', '2026-04-20T10:00:00Z', '/tmp/engram', 'engram', 'gpt-5.4', 2, 1, 1, '/tmp/too-old.jsonl', 48, '2026-04-20T10:00:00Z');
                INSERT INTO sessions_fts(session_id, content) VALUES ('wrong-project', 'hello from swift service');
                INSERT INTO sessions_fts(session_id, content) VALUES ('wrong-source', 'hello from swift service');
                INSERT INTO sessions_fts(session_id, content) VALUES ('too-old', 'hello from swift service');
                """
            )
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let search = try await provider.search(
            EngramServiceSearchRequest(
                query: "hello",
                mode: "keyword",
                limit: 10,
                project: "engram",
                source: "codex",
                since: "2026-04-22T00:00:00Z"
            )
        )

        XCTAssertEqual(search.items.map(\.id), ["s1"])
    }

    func testSQLiteReadProviderReusesOpenedReaderAcrossRepeatedReads() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let factory = CountingServiceDatabaseReaderFactory()
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            makeDatabaseReader: factory.makeReader(path:)
        )

        let first = try await provider.sources()
        XCTAssertEqual(first, [
            EngramServiceSourceInfo(name: "codex", sessionCount: 2, latestIndexed: "2026-04-23T02:00:00Z")
        ])

        let second = try await provider.sources()
        XCTAssertEqual(second, first)
        let embedding = try await provider.embeddingStatus()
        XCTAssertTrue(embedding.available)
        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(factory.reader?.readCount, 3)
    }

    func testSQLiteReadProviderBuildsResumeCommand() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            readProvider: try SQLiteEngramServiceReadProvider(
                databasePath: paths.database.path,
                commandLocator: { command in
                    command == "codex" ? "/usr/local/bin/codex" : nil
                }
            )
        )
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let resume = try await client.resumeCommand(sessionId: "s1")

        XCTAssertEqual(resume.tool, "codex")
        XCTAssertEqual(resume.command, "/usr/local/bin/codex")
        XCTAssertEqual(resume.args, ["--resume", "s1"])
        XCTAssertEqual(resume.cwd, "/tmp/engram")
        XCTAssertNil(resume.error)
    }

    func testExportSessionWritesThroughServiceCommand() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("s1.jsonl")
        try """
        {"role":"user","content":"<SYSTEM_MESSAGE>hidden legacy system</SYSTEM_MESSAGE>"}
        {"role":"user","content":"hello"}
        {"role":"assistant","content":"world"}
        {"role":"user","content":"<local-command-stdout>hidden agent comm</local-command-stdout>"}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET source = 'antigravity-legacy', file_path = ?, message_count = 4, user_message_count = 3, assistant_message_count = 1, tool_message_count = 0 WHERE id = 's1'",
                arguments: [transcript.path]
            )
        }

        let exportHome = paths.runtime.appendingPathComponent("home", isDirectory: true)
        let homeScope = ServiceCoreTestHomeScope(home: exportHome)
        defer { homeScope.restore() }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let response = try await client.exportSession(
            EngramServiceExportSessionRequest(id: "s1", format: "json", outputHome: exportHome.path, actor: "test")
        )

        XCTAssertEqual(response.format, "json")
        XCTAssertEqual(response.messageCount, 2)
        XCTAssertEqual(response.outputPath, exportHome.appendingPathComponent("codex-exports/antigravity-legacy-s1-2026-04-23.json").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: response.outputPath))
        let exported = try String(contentsOfFile: response.outputPath, encoding: .utf8)
        XCTAssertTrue(exported.contains("hello"), exported)
        XCTAssertTrue(exported.contains("world"), exported)
        XCTAssertFalse(exported.contains("hidden legacy system"), exported)
        XCTAssertFalse(exported.contains("hidden agent comm"), exported)
    }

    func testExportSessionUsesFullIdSoPrefixCollisionsDoNotOverwrite() async throws {
        // data-integrity: the filename used to take only the first 8 chars of
        // the session id. Two sessions sharing that prefix (and date) collided
        // and silently overwrote each other. Using the full id keeps them
        // distinct.
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcriptA = paths.runtime.appendingPathComponent("collideA.jsonl")
        let transcriptB = paths.runtime.appendingPathComponent("collideB.jsonl")
        try "{\"role\":\"user\",\"content\":\"alpha body\"}\n".write(to: transcriptA, atomically: true, encoding: .utf8)
        try "{\"role\":\"user\",\"content\":\"beta body\"}\n".write(to: transcriptB, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, model, message_count,
                  user_message_count, assistant_message_count, file_path, size_bytes, indexed_at
                ) VALUES
                  ('prefix12-AAAA', 'antigravity-legacy', '2026-04-23T01:00:00Z', '/tmp/engram', 'engram', 'm', 1, 1, 0, ?, 10, '2026-04-23T01:00:00Z'),
                  ('prefix12-BBBB', 'antigravity-legacy', '2026-04-23T01:00:00Z', '/tmp/engram', 'engram', 'm', 1, 1, 0, ?, 10, '2026-04-23T01:00:00Z');
                """,
                arguments: [transcriptA.path, transcriptB.path]
            )
        }

        let exportHome = paths.runtime.appendingPathComponent("home", isDirectory: true)
        let homeScope = ServiceCoreTestHomeScope(home: exportHome)
        defer { homeScope.restore() }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let responseA = try await client.exportSession(
            EngramServiceExportSessionRequest(id: "prefix12-AAAA", format: "markdown", outputHome: exportHome.path, actor: "test")
        )
        let responseB = try await client.exportSession(
            EngramServiceExportSessionRequest(id: "prefix12-BBBB", format: "markdown", outputHome: exportHome.path, actor: "test")
        )

        XCTAssertNotEqual(responseA.outputPath, responseB.outputPath, "prefix-colliding ids must export to distinct files")
        XCTAssertTrue(FileManager.default.fileExists(atPath: responseA.outputPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: responseB.outputPath))
        // The right session landed in the right file — each export carries its
        // own full id in the header. (Content-body rendering is exercised by the
        // transcript-reader tests; this test's concern is filename collisions.)
        let bodyA = try String(contentsOfFile: responseA.outputPath, encoding: .utf8)
        let bodyB = try String(contentsOfFile: responseB.outputPath, encoding: .utf8)
        XCTAssertTrue(bodyA.contains("prefix12-AAAA"), bodyA)
        XCTAssertTrue(bodyB.contains("prefix12-BBBB"), bodyB)
    }

    func testExportSessionFilenameFallsBackWhenStartTimeIsEmpty() async throws {
        // data-integrity: an empty start_time used to leave a dangling
        // "source-id-.ext" filename. A stable "undated" token is used instead.
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("undated.jsonl")
        try "{\"role\":\"user\",\"content\":\"undated body\"}\n".write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, model, message_count,
                  user_message_count, assistant_message_count, file_path, size_bytes, indexed_at
                ) VALUES
                  ('no-start-time', 'antigravity-legacy', '', '/tmp/engram', 'engram', 'm', 1, 1, 0, ?, 10, '2026-04-23T01:00:00Z');
                """,
                arguments: [transcript.path]
            )
        }

        let exportHome = paths.runtime.appendingPathComponent("home", isDirectory: true)
        let homeScope = ServiceCoreTestHomeScope(home: exportHome)
        defer { homeScope.restore() }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let response = try await client.exportSession(
            EngramServiceExportSessionRequest(id: "no-start-time", format: "markdown", outputHome: exportHome.path, actor: "test")
        )

        XCTAssertEqual(
            response.outputPath,
            exportHome.appendingPathComponent("codex-exports/antigravity-legacy-no-start-time-undated.md").path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: response.outputPath))
    }

    func testExportSessionDoesNotAdvanceDatabaseGeneration() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("s1.jsonl")
        try """
        {"timestamp":"2026-04-23T01:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE sessions SET file_path = ? WHERE id = 's1'", arguments: [transcript.path])
        }

        let exportHome = paths.runtime.appendingPathComponent("home", isDirectory: true)
        let homeScope = ServiceCoreTestHomeScope(home: exportHome)
        defer { homeScope.restore() }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let request = EngramServiceRequestEnvelope(
            command: "exportSession",
            payload: try JSONEncoder().encode(
                EngramServiceExportSessionRequest(id: "s1", format: "json", outputHome: exportHome.path, actor: "test")
            )
        )
        let response = try await UnixSocketEngramServiceTransport(socketPath: paths.socket.path).send(request, timeout: 2)
        guard case .success(_, _, let generation) = response else {
            return XCTFail("Expected successful export response")
        }
        XCTAssertNil(generation, "exportSession must not pretend to mutate the database")
    }

    func testExportSessionFiltersToolMessagesLikeSwiftDisplay() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("commandcode-session.jsonl")
        try """
        {"id":"msg-001","sessionId":"commandcode-session-001","parentId":null,"role":"user","cwd":"/Users/test/my-project","content":[{"type":"text","text":"检查解析器"}],"timestamp":"2026-05-20T02:00:00.000Z"}
        {"id":"msg-002","sessionId":"commandcode-session-001","parentId":"msg-001","role":"assistant","cwd":"/Users/test/my-project","model":"command-code-agent","content":[{"type":"text","text":"我会检查解析器。"},{"type":"tool-call","toolCallId":"tool-001","toolName":"read_file","input":{"path":"/Users/test/my-project/src/parser.ts"}}],"timestamp":"2026-05-20T02:00:01.000Z"}
        {"id":"msg-003","sessionId":"commandcode-session-001","parentId":"msg-002","role":"tool","cwd":"/Users/test/my-project","content":[{"type":"tool-result","toolCallId":"tool-001","toolName":"read_file","output":"file contents omitted"}],"timestamp":"2026-05-20T02:00:02.000Z"}
        {"id":"msg-004","sessionId":"commandcode-session-001","parentId":"msg-003","role":"assistant","cwd":"/Users/test/my-project","content":"   ","timestamp":"2026-05-20T02:00:03.000Z"}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET source = 'commandcode', file_path = ?, message_count = 3, user_message_count = 1, assistant_message_count = 1, tool_message_count = 1 WHERE id = 's1'",
                arguments: [transcript.path]
            )
        }

        let exportHome = paths.runtime.appendingPathComponent("home", isDirectory: true)
        let homeScope = ServiceCoreTestHomeScope(home: exportHome)
        defer { homeScope.restore() }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let response = try await client.exportSession(
            EngramServiceExportSessionRequest(id: "s1", format: "json", outputHome: exportHome.path, actor: "test")
        )

        XCTAssertEqual(response.messageCount, 2)
        let data = try Data(contentsOf: URL(fileURLWithPath: response.outputPath))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["user", "assistant"])
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains(#""role" : "tool""#) ?? true)
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains(#""content" : "   ""#) ?? true)
    }

    func testExportSessionRedactsSecretsAndWritesOwnerOnlyFile() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("s1-secret.jsonl")
        try """
        {"timestamp":"2026-04-23T01:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Authorization: Bearer sk-test-secret-token-123456789"}]}}
        {"timestamp":"2026-04-23T01:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"password = hunter2hunter2"}]}}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE sessions SET file_path = ? WHERE id = 's1'", arguments: [transcript.path])
        }

        let exportHome = paths.runtime.appendingPathComponent("home", isDirectory: true)
        let homeScope = ServiceCoreTestHomeScope(home: exportHome)
        defer { homeScope.restore() }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let response = try await client.exportSession(
            EngramServiceExportSessionRequest(id: "s1", format: "markdown", outputHome: exportHome.path, actor: "test")
        )

        let content = try String(contentsOfFile: response.outputPath, encoding: .utf8)
        XCTAssertTrue(content.contains("[REDACTED]"))
        XCTAssertFalse(content.contains("sk-test-secret-token"))
        XCTAssertFalse(content.contains("hunter2hunter2"))

        var info = stat()
        XCTAssertEqual(lstat(response.outputPath, &info), 0)
        XCTAssertEqual(info.st_mode & 0o077, 0)
    }

    func testExportSessionUsesRequestedHomeInsteadOfServiceHome() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("s1.jsonl")
        try """
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"client home"}]}}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE sessions SET file_path = ? WHERE id = 's1'", arguments: [transcript.path])
        }

        let serviceHome = paths.runtime.appendingPathComponent("service-home", isDirectory: true)
        let clientHome = serviceHome.appendingPathComponent("client-home", isDirectory: true)
        let homeScope = ServiceCoreTestHomeScope(home: serviceHome)
        defer { homeScope.restore() }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let response = try await client.exportSession(
            EngramServiceExportSessionRequest(id: "s1", format: "json", outputHome: clientHome.path, actor: "test")
        )

        XCTAssertTrue(response.outputPath.hasPrefix(clientHome.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: serviceHome.appendingPathComponent("codex-exports").path))
    }

    func testExportSessionRejectsOutputHomeOutsideServiceHome() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("s1.jsonl")
        try """
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"outside home"}]}}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE sessions SET file_path = ? WHERE id = 's1'", arguments: [transcript.path])
        }

        let serviceHome = paths.runtime.appendingPathComponent("service-home", isDirectory: true)
        let outsideHome = paths.runtime.appendingPathComponent("outside-home", isDirectory: true)
        let homeScope = ServiceCoreTestHomeScope(home: serviceHome)
        defer { homeScope.restore() }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        do {
            _ = try await client.exportSession(
                EngramServiceExportSessionRequest(id: "s1", format: "json", outputHome: outsideHome.path, actor: "test")
            )
            XCTFail("Expected invalidRequest for output_home outside HOME")
        } catch let error as EngramServiceError {
            XCTAssertEqual(error, .invalidRequest(message: "output_home must be within HOME"))
        }
    }

    func testExportSessionRejectsCodexExportsSymlink() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("s1.jsonl")
        try """
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"symlink"}]}}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE sessions SET file_path = ? WHERE id = 's1'", arguments: [transcript.path])
        }

        let serviceHome = paths.runtime.appendingPathComponent("service-home", isDirectory: true)
        let outside = paths.runtime.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: serviceHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: serviceHome.appendingPathComponent("codex-exports"),
            withDestinationURL: outside
        )
        let homeScope = ServiceCoreTestHomeScope(home: serviceHome)
        defer { homeScope.restore() }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        do {
            _ = try await client.exportSession(
                EngramServiceExportSessionRequest(id: "s1", format: "json", outputHome: serviceHome.path, actor: "test")
            )
            XCTFail("Expected invalidRequest for symlinked codex-exports")
        } catch let error as EngramServiceError {
            XCTAssertEqual(error, .invalidRequest(message: "output_home must not traverse symlinks"))
        }
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
    }

    func testExportSessionRejectsLeafOutputSymlink() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("s1.jsonl")
        try """
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"leaf symlink"}]}}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE sessions SET file_path = ? WHERE id = 's1'", arguments: [transcript.path])
        }

        let serviceHome = paths.runtime.appendingPathComponent("service-home", isDirectory: true)
        let outputDir = serviceHome.appendingPathComponent("codex-exports", isDirectory: true)
        let outside = paths.runtime.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideTarget = outside.appendingPathComponent("stolen.json")
        try FileManager.default.createSymbolicLink(
            at: outputDir.appendingPathComponent("codex-s1-2026-04-23.json"),
            withDestinationURL: outsideTarget
        )
        let homeScope = ServiceCoreTestHomeScope(home: serviceHome)
        defer { homeScope.restore() }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        do {
            _ = try await client.exportSession(
                EngramServiceExportSessionRequest(id: "s1", format: "json", outputHome: serviceHome.path, actor: "test")
            )
            XCTFail("Expected invalidRequest for symlinked export target")
        } catch let error as EngramServiceError {
            XCTAssertEqual(error, .invalidRequest(message: "output_home must not traverse symlinks"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideTarget.path))
    }

    func testExportSessionRejectsInvalidFormat() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        do {
            _ = try await client.exportSession(
                EngramServiceExportSessionRequest(id: "s1", format: "html", outputHome: paths.runtime.path, actor: "test")
            )
            XCTFail("Invalid export format should fail")
        } catch let error as EngramServiceError {
            XCTAssertEqual(error, .invalidRequest(message: "Unsupported export format: html"))
        }
    }

    func testExportSessionSupportsCopilotSource() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("copilot-events.jsonl")
        try """
        {"timestamp":"2026-04-23T01:00:01Z","type":"user.message","data":{"content":"copilot user"}}
        {"timestamp":"2026-04-23T01:00:02Z","type":"assistant.message","data":{"content":"copilot assistant"}}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO sessions (id, source, start_time, cwd, project, message_count, user_message_count, assistant_message_count, file_path, size_bytes, indexed_at) VALUES ('copilot-1', 'copilot', '2026-04-23T01:00:00Z', '/tmp/engram', 'engram', 2, 1, 1, ?, 1, '2026-04-23T01:00:00Z')",
                arguments: [transcript.path]
            )
        }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let exportHome = paths.runtime.appendingPathComponent("home", isDirectory: true)
        let homeScope = ServiceCoreTestHomeScope(home: exportHome)
        defer { homeScope.restore() }
        let response = try await client.exportSession(
            EngramServiceExportSessionRequest(id: "copilot-1", format: "json", outputHome: exportHome.path, actor: "test")
        )

        XCTAssertEqual(response.messageCount, 2)
        let content = try String(contentsOfFile: response.outputPath, encoding: .utf8)
        XCTAssertTrue(content.contains("copilot user"))
        XCTAssertTrue(content.contains("copilot assistant"))
    }

    func testSQLiteProviderServesProjectReadsAndSuggestionMutations() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            readProvider: try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)
        )
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))

        let migrations = try await client.projectMigrations(
            EngramServiceProjectMigrationsRequest(state: "committed", limit: 5)
        )
        XCTAssertEqual(migrations.migrations.map(\.id), ["mig-1"])

        let cwds = try await client.projectCwds(project: "engram")
        XCTAssertEqual(cwds.cwds, ["/tmp/engram"])

        let confirm = try await client.confirmSuggestion(sessionId: "s2")
        XCTAssertEqual(confirm, EngramServiceLinkResponse(ok: true, error: nil))

        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, suggested_parent_id, link_source FROM sessions WHERE id = 's2'"
            )
            XCTAssertEqual(row?["parent_session_id"] as String?, "s1")
            XCTAssertNil(row?["suggested_parent_id"] as String?)
            XCTAssertEqual(row?["link_source"] as String?, "manual")
        }

        try await queue.write { db in
            try db.execute(
                sql: """
                    UPDATE sessions
                    SET suggested_parent_id = 's1', parent_session_id = NULL, link_source = NULL
                    WHERE id = 's2'
                """
            )
        }

        try await client.dismissSuggestion(sessionId: "s2", suggestedParentId: "s1")
        try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, suggested_parent_id FROM sessions WHERE id = 's2'"
            )
            XCTAssertNil(row?["parent_session_id"] as String?)
            XCTAssertNil(row?["suggested_parent_id"] as String?)
        }
    }

    func testManualParentLinkAndUnlinkRoundTripThroughClient() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            readProvider: try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)
        )
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))

        let linked = try await client.setParentSession(sessionId: "s2", parentId: "s1")
        XCTAssertEqual(linked, EngramServiceLinkResponse(ok: true, error: nil))

        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, suggested_parent_id, link_source FROM sessions WHERE id = 's2'"
            )
            XCTAssertEqual(row?["parent_session_id"] as String?, "s1")
            XCTAssertNil(row?["suggested_parent_id"] as String?)
            XCTAssertEqual(row?["link_source"] as String?, "manual")
        }

        let unlinked = try await client.clearParentSession(sessionId: "s2")
        XCTAssertEqual(unlinked, EngramServiceLinkResponse(ok: true, error: nil))

        try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, link_source FROM sessions WHERE id = 's2'"
            )
            XCTAssertNil(row?["parent_session_id"] as String?)
            XCTAssertEqual(row?["link_source"] as String?, "manual")
        }
    }

    func testFileSystemProviderReportsRecentlyModifiedLiveSessions() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-live-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root
            .appendingPathComponent(".codex/sessions/2026/05/24", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let sessionFile = sessionDir.appendingPathComponent("rollout.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"live-codex","cwd":"/tmp/engram","model":"gpt-5"}}
        {"type":"turn_context","cwd":"/tmp/engram"}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: sessionFile.path)

        let provider = FileSystemEngramServiceReadProvider(homeDirectory: root)
        let response = try await provider.liveSessions()

        XCTAssertEqual(response.count, 1)
        XCTAssertEqual(response.sessions.first?.source, "codex")
        XCTAssertEqual(response.sessions.first?.sessionId, "live-codex")
        XCTAssertEqual(response.sessions.first?.activityLevel, "active")
    }

    func testLinkSessionsRejectsPathsOutsideKnownSessionRoots() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let home = paths.runtime.appendingPathComponent("home", isDirectory: true)
        let allowedDir = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let deniedDir = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deniedDir, withIntermediateDirectories: true)
        let allowedFile = allowedDir.appendingPathComponent("allowed.jsonl")
        let deniedFile = deniedDir.appendingPathComponent("id_rsa")
        try "{}\n".write(to: allowedFile, atomically: true, encoding: .utf8)
        try "secret\n".write(to: deniedFile, atomically: true, encoding: .utf8)

        let homeScope = ServiceCoreTestHomeScope(home: home)
        defer { homeScope.restore() }

        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE sessions SET file_path = ? WHERE id = 's1'", arguments: [allowedFile.path])
            try db.execute(sql: "UPDATE sessions SET file_path = ? WHERE id = 's2'", arguments: [deniedFile.path])
        }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let targetDir = home.appendingPathComponent("engram", isDirectory: true)
        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let response = try await client.linkSessions(
            EngramServiceLinkSessionsRequest(targetDir: targetDir.path, actor: "test")
        )

        XCTAssertEqual(response.created, 1)
        XCTAssertEqual(response.errors.count, 1)
        XCTAssertTrue(response.errors[0].contains("refusing to link path outside known session roots"))
        let linkPath = targetDir.appendingPathComponent("conversation_log/codex/allowed.jsonl").path
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkPath), allowedFile.path)
    }

    func testLinkSessionsDoesNotReplaceExistingDifferentSymlink() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let home = paths.runtime.appendingPathComponent("home", isDirectory: true)
        let allowedDir = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedDir, withIntermediateDirectories: true)
        let allowedFile = allowedDir.appendingPathComponent("allowed.jsonl")
        let existingTarget = allowedDir.appendingPathComponent("existing.jsonl")
        try "{}\n".write(to: allowedFile, atomically: true, encoding: .utf8)
        try "{}\n".write(to: existingTarget, atomically: true, encoding: .utf8)

        let homeScope = ServiceCoreTestHomeScope(home: home)
        defer { homeScope.restore() }

        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE sessions SET file_path = ? WHERE id = 's1'", arguments: [allowedFile.path])
            try db.execute(sql: "UPDATE sessions SET hidden_at = '2026-04-23T03:00:00Z' WHERE id = 's2'")
        }

        let targetDir = home.appendingPathComponent("engram", isDirectory: true)
        let linkDir = targetDir.appendingPathComponent("conversation_log/codex", isDirectory: true)
        try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
        let linkPath = linkDir.appendingPathComponent("allowed.jsonl").path
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: existingTarget.path)

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let response = try await client.linkSessions(
            EngramServiceLinkSessionsRequest(targetDir: targetDir.path, actor: "test")
        )

        XCTAssertEqual(response.created, 0)
        XCTAssertTrue(response.errors.contains { $0.contains("refusing to replace existing symlink") })
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkPath), existingTarget.path)
    }

    func testLinkSessionsRejectsTargetDirectoryOutsideHome() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let home = paths.runtime.appendingPathComponent("home", isDirectory: true)
        let targetOutsideHome = paths.runtime.appendingPathComponent("outside-home", isDirectory: true)
        let allowedDir = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedDir, withIntermediateDirectories: true)
        let allowedFile = allowedDir.appendingPathComponent("allowed.jsonl")
        try "{}\n".write(to: allowedFile, atomically: true, encoding: .utf8)

        let homeScope = ServiceCoreTestHomeScope(home: home)
        defer { homeScope.restore() }

        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE sessions SET file_path = ? WHERE id = 's1'", arguments: [allowedFile.path])
        }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))

        do {
            _ = try await client.linkSessions(
                EngramServiceLinkSessionsRequest(targetDir: targetOutsideHome.path, actor: "test")
            )
            XCTFail("linkSessions target outside HOME should be rejected")
        } catch {
            XCTAssertTrue("\(error)".contains("targetDir path resolves outside the home directory"), "\(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: targetOutsideHome.path),
            "Rejected linkSessions target must not be created"
        )
    }

    func testLinkSessionsDoesNotRunThroughTheWriteGate() async throws {
        // concurrency: linkSessions only reads via an independent read-only
        // queue and creates filesystem symlinks; it never writes the database.
        // It must NOT run through the single write gate (which would hold the
        // gate for up to 10k symlink ops, blocking real writes). A command that
        // ran through performWriteCommand advances the database generation; a
        // command that bypasses the gate reports no generation.
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let home = paths.runtime.appendingPathComponent("home", isDirectory: true)
        let allowedDir = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedDir, withIntermediateDirectories: true)
        let allowedFile = allowedDir.appendingPathComponent("allowed.jsonl")
        try "{}\n".write(to: allowedFile, atomically: true, encoding: .utf8)

        let homeScope = ServiceCoreTestHomeScope(home: home)
        defer { homeScope.restore() }

        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE sessions SET file_path = ? WHERE id = 's1'", arguments: [allowedFile.path])
        }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let targetDir = home.appendingPathComponent("engram", isDirectory: true)
        let request = EngramServiceRequestEnvelope(
            command: "linkSessions",
            payload: try JSONEncoder().encode(
                EngramServiceLinkSessionsRequest(targetDir: targetDir.path, actor: "test")
            )
        )
        let response = try await UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
            .send(request, timeout: 2)
        guard case .success(_, _, let generation) = response else {
            return XCTFail("Expected successful linkSessions response, got \(response)")
        }
        XCTAssertNil(generation, "linkSessions does not write the DB and must not advance the database generation")
    }

    func testAppSessionMetadataMutationsAreOwnedByServiceWriterGate() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE sessions SET message_count = 0, size_bytes = 512 WHERE id = 's2'")
        }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))

        try await client.setFavorite(sessionId: "s1", favorite: true)
        try await client.renameSession(sessionId: "s1", name: "Pinned session")
        try await client.setSessionHidden(sessionId: "s1", hidden: true)
        try await client.setSessionHidden(sessionId: "s1", hidden: false)

        let hidden = try await client.hideEmptySessions()
        XCTAssertEqual(hidden.hiddenCount, 1)

        try await queue.read { db in
            let favorite = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM favorites WHERE session_id = 's1'"
            )
            XCTAssertEqual(favorite, 1)

            let s1 = try Row.fetchOne(
                db,
                sql: "SELECT hidden_at, custom_name FROM sessions WHERE id = 's1'"
            )
            XCTAssertNil(s1?["hidden_at"] as String?)
            XCTAssertEqual(s1?["custom_name"] as String?, "Pinned session")

            let s2 = try Row.fetchOne(
                db,
                sql: "SELECT hidden_at FROM sessions WHERE id = 's2'"
            )
            XCTAssertNotNil(s2?["hidden_at"] as String?)
        }

        try await client.setFavorite(sessionId: "s1", favorite: false)
        try await queue.read { db in
            let favorite = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM favorites WHERE session_id = 's1'"
            )
            XCTAssertEqual(favorite, 0)
        }
    }

    func testInsightAndProjectAliasMutationsAreOwnedByServiceWriterGate() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let insight = try await client.saveInsight(
            EngramServiceSaveInsightRequest(
                content: "Swift service owns insight writes",
                wing: "engram",
                room: "stage5",
                importance: 4,
                sourceSessionId: "s1",
                actor: "test"
            )
        )
        let insightObject = try XCTUnwrap(insight.objectValue)
        let insightId = try XCTUnwrap(insightObject["id"]?.stringValue)

        _ = try await client.manageProjectAlias(
            EngramServiceProjectAliasRequest(
                action: "add",
                oldProject: "engram-old",
                newProject: "engram",
                actor: "test"
            )
        )

        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.read { db in
            let insightRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT content, wing, room, importance, source_session_id
                    FROM insights
                    WHERE id = ?
                """,
                arguments: [insightId]
            )
            XCTAssertEqual(insightRow?["content"] as String?, "Swift service owns insight writes")
            XCTAssertEqual(insightRow?["wing"] as String?, "engram")
            XCTAssertEqual(insightRow?["room"] as String?, "stage5")
            XCTAssertEqual(insightRow?["importance"] as Int?, 4)
            XCTAssertEqual(insightRow?["source_session_id"] as String?, "s1")

            let ftsCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM insights_fts WHERE insight_id = ?",
                arguments: [insightId]
            )
            XCTAssertEqual(ftsCount, 1)

            let aliasCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM project_aliases
                    WHERE alias = 'engram-old' AND canonical = 'engram'
                """
            )
            XCTAssertEqual(aliasCount, 1)
        }

        _ = try await client.manageProjectAlias(
            EngramServiceProjectAliasRequest(
                action: "remove",
                oldProject: "engram-old",
                newProject: "engram",
                actor: "test"
            )
        )

        try await queue.read { db in
            let aliasCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM project_aliases
                    WHERE alias = 'engram-old' AND canonical = 'engram'
                """
            )
            XCTAssertEqual(aliasCount, 0)
        }
    }

    func testDeleteInsightRemovesInsightAndFtsRowsThroughServiceWriterGate() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let insight = try await client.saveInsight(
            EngramServiceSaveInsightRequest(
                content: "Swift service should delete insight and search rows",
                wing: "engram",
                room: "stage5",
                importance: 4,
                sourceSessionId: "s1",
                actor: "test"
            )
        )
        let insightId = try XCTUnwrap(insight.objectValue?["id"]?.stringValue)

        let transport = UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        let deleteResponse = try await transport.send(
            EngramServiceRequestEnvelope(
                command: "deleteInsight",
                payload: try JSONSerialization.data(withJSONObject: ["id": insightId])
            ),
            timeout: 2
        )

        guard case .success(_, let data, let generation?) = deleteResponse else {
            throw EngramServiceError.invalidRequest(message: "Expected successful deleteInsight response")
        }
        XCTAssertGreaterThanOrEqual(generation, 2)
        let result = try JSONDecoder().decode(EngramServiceJSONValue.self, from: data)
        XCTAssertEqual(result.objectValue?["deleted"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["id"]?.stringValue, insightId)

        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insights WHERE id = ?", arguments: [insightId]),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insights_fts WHERE insight_id = ?", arguments: [insightId]),
                0
            )
        }
    }

    func testFormerBridgeCommandsUseNativeServiceBehavior() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            readProvider: try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)
        )
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))

        let hygiene = try await client.hygiene(force: false)
        XCTAssertEqual(hygiene.score, 0)
        XCTAssertEqual(hygiene.issues.first?.kind, "hygiene")
        XCTAssertEqual(hygiene.issues.first?.severity, "info")
        XCTAssertFalse(hygiene.checkedAt.isEmpty)

        let handoff = try await client.handoff(
            EngramServiceHandoffRequest(cwd: "/tmp/engram", sessionId: nil, format: "markdown")
        )
        XCTAssertEqual(handoff.sessionCount, 2)
        XCTAssertTrue(handoff.brief.contains("## Handoff"))
        XCTAssertTrue(handoff.brief.contains("Generated Title"))

        let summary = try await client.generateSummary(EngramServiceGenerateSummaryRequest(sessionId: "s1"))
        XCTAssertTrue(summary.summary.contains("Generated Title"))

        let sync = try await client.triggerSync(EngramServiceTriggerSyncRequest(peer: "laptop"))
        XCTAssertEqual(sync.results, [
            EngramServiceTriggerSyncResponse.ResultItem(
                peer: "laptop",
                ok: false,
                pulled: 0,
                pushed: 0,
                error: "Sync is not implemented in the Swift service"
            )
        ])

        let titles = try await client.regenerateAllTitles()
        XCTAssertEqual(titles.status, "completed")
        XCTAssertEqual(titles.total, 1)
    }

    func testProjectMigrationCommandsSurfacePipelineErrors() async throws {
        // Stage 4 ships native project move/archive/undo/move-batch handlers
        // wired through ProjectMoveOrchestrator. The previous fail-closed
        // contract (UnsupportedNativeCommand / retryPolicy=never) is gone;
        // commands now reach the pipeline and surface its real errors.
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let home = paths.runtime.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let homeScope = ServiceCoreTestHomeScope(home: home)
        defer { homeScope.restore() }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))

        // 1a. SEC-C2: out-of-home src is refused at the boundary BEFORE the
        //     pipeline, even with force=true. /tmp is outside HOME.
        do {
            _ = try await client.projectMove(
                EngramServiceProjectMoveRequest(
                    src: "/tmp/no-such-engram-src-\(UUID().uuidString)",
                    dst: "/tmp/no-such-engram-dst-\(UUID().uuidString)",
                    dryRun: false,
                    force: true,
                    auditNote: "fixture",
                    actor: "test"
                )
            )
            XCTFail("out-of-home projectMove must be refused")
        } catch let error as EngramServiceError {
            guard case .invalidRequest(let message) = error else {
                XCTFail("expected invalidRequest confinement error, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("outside the home directory"), message)
        }

        // 1b. In-home but absent src reaches the pipeline and surfaces a real
        //     OrchestratorError (not UnsupportedNativeCommand, not confinement).
        do {
            _ = try await client.projectMove(
                EngramServiceProjectMoveRequest(
                    src: home.appendingPathComponent(".engram-test-missing-src-\(UUID().uuidString)").path,
                    dst: home.appendingPathComponent(".engram-test-missing-dst-\(UUID().uuidString)").path,
                    dryRun: false,
                    force: false,
                    auditNote: "fixture",
                    actor: "test"
                )
            )
            XCTFail("projectMove on absent src should fail")
        } catch let error as EngramServiceError {
            guard case .commandFailed(let name, _, _, _) = error else {
                XCTFail("expected commandFailed, got \(error)")
                return
            }
            XCTAssertNotEqual(name, "UnsupportedNativeCommand", "command must reach the pipeline")
        }

        // 2. projectUndo: missing migration id surfaces UndoMigrationError.
        do {
            _ = try await client.projectUndo(
                EngramServiceProjectUndoRequest(migrationId: "missing-id", force: false, actor: "test")
            )
            XCTFail("projectUndo on missing id should fail")
        } catch let error as EngramServiceError {
            guard case .commandFailed(let name, _, _, _) = error else {
                XCTFail("expected commandFailed, got \(error)")
                return
            }
            XCTAssertNotEqual(name, "UnsupportedNativeCommand")
        }

        // 3. projectMoveBatch: empty JSON document is a valid no-op.
        let emptyBatch = try await client.projectMoveBatch(
            EngramServiceProjectMoveBatchRequest(
                yaml: #"{"version":1,"operations":[]}"#,
                dryRun: true,
                force: false,
                actor: "test"
            )
        )
        // empty batch → completed=[], failed=[], skipped=[]
        guard case .object(let obj) = emptyBatch else {
            XCTFail("expected object batch result, got \(emptyBatch)")
            return
        }
        if case .array(let completed) = obj["completed"] ?? .null {
            XCTAssertTrue(completed.isEmpty)
        } else {
            XCTFail("expected `completed` array")
        }

        // 4. projectMoveBatch: malformed JSON surfaces BatchError as commandFailed.
        do {
            _ = try await client.projectMoveBatch(
                EngramServiceProjectMoveBatchRequest(
                    yaml: "{ not json",
                    dryRun: false,
                    force: false,
                    actor: "test"
                )
            )
            XCTFail("malformed json should fail")
        } catch let error as EngramServiceError {
            guard case .commandFailed(let name, _, _, _) = error else {
                XCTFail("expected commandFailed, got \(error)")
                return
            }
            XCTAssertNotEqual(name, "UnsupportedNativeCommand")
        }
    }

    func testUnsupportedTriggerSyncDoesNotAdvanceDatabaseGeneration() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let transport = UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        let request = EngramServiceRequestEnvelope(
            command: "triggerSync",
            payload: try JSONEncoder().encode(EngramServiceTriggerSyncRequest(peer: "laptop"))
        )
        let response = try await transport.send(request, timeout: 2)

        guard case .success(_, let data, let generation) = response else {
            throw EngramServiceError.invalidRequest(message: "Expected unsupported sync response")
        }
        XCTAssertNil(generation)
        XCTAssertEqual(
            try JSONDecoder().decode(EngramServiceTriggerSyncResponse.self, from: data).results,
            [
                EngramServiceTriggerSyncResponse.ResultItem(
                    peer: "laptop",
                    ok: false,
                    pulled: 0,
                    pushed: 0,
                    error: "Sync is not implemented in the Swift service"
                )
            ]
        )
    }
}

private extension EngramServiceJSONValue {
    var objectValue: [String: EngramServiceJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

private func assertUnsupportedNativeCommand(
    _ command: String,
    operation: () async throws -> Void
) async throws {
    do {
        try await operation()
        XCTFail("\(command) should fail closed")
    } catch let error as EngramServiceError {
        guard case .commandFailed(let name, _, let retryPolicy, let details) = error else {
            XCTFail("Expected commandFailed for \(command), got \(error)")
            return
        }
        XCTAssertEqual(name, "UnsupportedNativeCommand")
        XCTAssertEqual(retryPolicy, "never")
        XCTAssertEqual(details?["command"], .string(command))
    }
}

private func writeIntentGeneration(from response: EngramServiceResponseEnvelope) throws -> Int {
    guard case .success(_, let data, let generation?) = response else {
        throw EngramServiceError.invalidRequest(message: "Expected successful write intent response")
    }
    let decoded = try JSONDecoder().decode([String: Bool].self, from: data)
    XCTAssertEqual(decoded["ok"], true)
    return generation
}

private func makeServiceIPCPaths() throws -> (runtime: URL, socket: URL, database: URL) {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("engram-ipc-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let runtime = root.appendingPathComponent("run", isDirectory: true)
    try FileManager.default.createDirectory(
        at: runtime,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return (
        runtime,
        runtime.appendingPathComponent("service.sock"),
        root.appendingPathComponent("service.sqlite")
    )
}

private func waitUntilFileExists(_ path: String) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: path) {
        if Date() >= deadline {
            XCTFail("timed out waiting for \(path)")
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

private func seedSearchFixture(at path: String) throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
        try db.execute(sql: "PRAGMA journal_mode = WAL")
    }
    let queue = try DatabaseQueue(path: path, configuration: configuration)
    try queue.write { db in
        try db.execute(sql: """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY,
              source TEXT NOT NULL,
              start_time TEXT NOT NULL,
              end_time TEXT,
              cwd TEXT NOT NULL DEFAULT '',
              project TEXT,
              model TEXT,
              message_count INTEGER NOT NULL DEFAULT 0,
              user_message_count INTEGER NOT NULL DEFAULT 0,
              assistant_message_count INTEGER NOT NULL DEFAULT 0,
              tool_message_count INTEGER NOT NULL DEFAULT 0,
              system_message_count INTEGER NOT NULL DEFAULT 0,
              summary TEXT,
              file_path TEXT NOT NULL,
              source_locator TEXT,
              size_bytes INTEGER NOT NULL DEFAULT 0,
              indexed_at TEXT NOT NULL,
              agent_role TEXT,
              hidden_at TEXT,
              custom_name TEXT,
              tier TEXT,
              origin TEXT,
              summary_message_count INTEGER,
              quality_score INTEGER,
              generated_title TEXT,
              parent_session_id TEXT,
              suggested_parent_id TEXT,
              link_source TEXT,
              link_checked_at TEXT,
              orphan_status TEXT,
              has_embedding INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE session_local_state (
              session_id TEXT PRIMARY KEY,
              local_readable_path TEXT
            );
            CREATE TABLE migration_log (
              id TEXT PRIMARY KEY,
              old_path TEXT NOT NULL,
              new_path TEXT NOT NULL,
              old_basename TEXT NOT NULL,
              new_basename TEXT NOT NULL,
              state TEXT NOT NULL,
              started_at TEXT NOT NULL,
              finished_at TEXT,
              archived INTEGER NOT NULL DEFAULT 0,
              audit_note TEXT,
              actor TEXT NOT NULL DEFAULT 'app'
            );
            CREATE TABLE project_aliases (
              alias TEXT NOT NULL,
              canonical TEXT NOT NULL,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              PRIMARY KEY (alias, canonical)
            );
            CREATE VIRTUAL TABLE sessions_fts USING fts5(
              session_id UNINDEXED,
              content,
              tokenize='trigram case_sensitive 0'
            );
            CREATE TABLE session_embeddings(session_id TEXT PRIMARY KEY);
            INSERT INTO sessions (
              id, source, start_time, cwd, project, model, message_count,
              user_message_count, assistant_message_count, file_path, size_bytes,
              indexed_at, generated_title, has_embedding
            ) VALUES (
              's1', 'codex', '2026-04-23T01:00:00Z', '/tmp/engram', 'engram',
              'gpt-5.4', 2, 1, 1, '/tmp/s1.jsonl', 42,
              '2026-04-23T01:30:00Z', 'Generated Title', 1
            );
            INSERT INTO sessions (
              id, source, start_time, cwd, project, model, message_count,
              user_message_count, assistant_message_count, file_path, size_bytes,
              indexed_at
            ) VALUES (
              's2', 'codex', '2026-04-23T02:00:00Z', '/tmp/engram', 'engram',
              'gpt-5.4', 2, 1, 1, '/tmp/s2.jsonl', 43,
              '2026-04-23T02:00:00Z'
            );
            UPDATE sessions SET suggested_parent_id = 's1' WHERE id = 's2';
            INSERT INTO sessions_fts(session_id, content) VALUES ('s1', 'hello from swift service');
            INSERT INTO sessions_fts(session_id, content) VALUES ('s2', 'different text');
            INSERT INTO session_embeddings(session_id) VALUES ('s1');
            INSERT INTO migration_log (
              id, old_path, new_path, old_basename, new_basename,
              state, started_at, finished_at, archived, audit_note, actor
            ) VALUES (
              'mig-1', '/tmp/old-engram', '/tmp/new-engram', 'old-engram', 'new-engram',
              'committed', '2026-04-23T03:00:00Z', '2026-04-23T03:05:00Z', 0, 'fixture', 'app'
            );
        """)
    }
}

private actor TitleConcurrencyProbe {
    private var current = 0
    private var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }

    func maximum() -> Int {
        peak
    }
}

private func serviceCoreSource(_ relativePath: String) throws -> String {
    var directory = URL(fileURLWithPath: #filePath)
    while directory.lastPathComponent != "macos" {
        directory.deleteLastPathComponent()
    }
    let file = directory.appendingPathComponent(relativePath)
    return try String(contentsOf: file, encoding: .utf8)
}

private final class CountingServiceDatabaseReaderFactory: @unchecked Sendable {
    private(set) var makeCount = 0
    private(set) var reader: CountingServiceDatabaseReader?

    func makeReader(path: String) throws -> any ServiceDatabaseReading {
        makeCount += 1
        let reader = try CountingServiceDatabaseReader(path: path)
        self.reader = reader
        return reader
    }
}

private final class CountingServiceDatabaseReader: ServiceDatabaseReading, @unchecked Sendable {
    private let queue: DatabaseQueue
    private(set) var readCount = 0

    init(path: String) throws {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA busy_timeout = 30000")
        }
        self.queue = try DatabaseQueue(path: path, configuration: configuration)
    }

    func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        readCount += 1
        return try queue.read(block)
    }
}
