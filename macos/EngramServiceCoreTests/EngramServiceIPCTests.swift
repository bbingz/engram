import XCTest
import GRDB
import Darwin
import Foundation
import EngramCoreRead
import EngramCoreWrite
@testable import EngramServiceCore

final class EngramServiceIPCTests: XCTestCase {
    func testServiceRunnerProductionPathsUseFileManagerHome_repro() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let start = try XCTUnwrap(source.range(of: "let runtimeHome ="))
        let end = try XCTUnwrap(source.range(of: "let settingsURL =", range: start.lowerBound..<source.endIndex))
        let startupPaths = source[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(startupPaths.contains("let serviceHome = isTestProcess"))
        XCTAssertTrue(startupPaths.contains("FileManager.default.homeDirectoryForCurrentUser"))
        XCTAssertTrue(startupPaths.contains("?? serviceHome"))
    }

    func testRunnerReconcilesInsightsBeforeStartingListener_repro() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let migrate = try XCTUnwrap(source.range(of: #"performWriteCommand(name: "migrate")"#))
        let listen = try XCTUnwrap(source.range(of: "try server.start()", range: migrate.lowerBound..<source.endIndex))
        let preListen = String(source[migrate.lowerBound..<listen.lowerBound])

        XCTAssertTrue(
            preListen.contains("StartupBackfills.reconcileInsights(db)"),
            "insight chains must be reconciled in the migration write before agent reads are served"
        )
    }

    func testServiceRunnerRejectsRelativeOrBlankPathFlags_repro() {
        for value in ["relative.sock", "relative/service.sock", "   "] {
            XCTAssertThrowsError(
                try engramServiceAbsoluteArgumentValue(
                    after: "--service-socket",
                    in: ["--service-socket", value]
                )
            )
        }
        XCTAssertEqual(
            try engramServiceAbsoluteArgumentValue(
                after: "--database-path",
                in: ["--database-path", "/tmp/engram.sqlite"]
            ),
            "/tmp/engram.sqlite"
        )
    }
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

    func testReadTitleContextsRegeneratesTitledNormalSessionsAndExcludesSkipTier() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceCommandHandler.swift")
        let start = try XCTUnwrap(source.range(of: "static func readTitleContexts"))
        let end = try XCTUnwrap(source.range(of: "private static func readOnlyPool"))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("COALESCE(tier, 'normal') != 'skip'"))
        XCTAssertFalse(
            body.contains("generated_title IS NULL"),
            "regenerate-all must not be starved by indexer-derived generated_title values"
        )
    }

    func testRegenerateAllTitlesCapturesAISettingsBeforeStartingBackgroundTask_repro() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceCommandHandler.swift")
        let start = try XCTUnwrap(source.range(of: "private static func regenerateAllTitles("))
        let end = try XCTUnwrap(
            source.range(
                of: "private static func regenerateAllTitlesInBackground(",
                range: start.upperBound..<source.endIndex
            )
        )
        let entrypoint = String(source[start.lowerBound..<end.lowerBound])
        let settingsRead = try XCTUnwrap(entrypoint.range(of: "ServiceAISettings.read()"))
        let backgroundStart = try XCTUnwrap(entrypoint.range(of: "titleRegenerationCoordinator.start"))

        XCTAssertLessThan(
            settingsRead.lowerBound,
            backgroundStart.lowerBound,
            "tests may restore a scoped HOME as soon as the async command returns"
        )
    }

    func testSQLiteResumeCommandUsesCodexResumeSubcommand() {
        XCTAssertEqual(
            SQLiteEngramServiceReadProvider.resumeArguments(tool: "codex", sessionId: "s1"),
            ["resume", "s1"]
        )
        XCTAssertEqual(
            SQLiteEngramServiceReadProvider.resumeArguments(tool: "claude", sessionId: "s1"),
            ["--resume", "s1"]
        )
    }

    func testReplayTimelineBuildsEntriesFromFtsRows() {
        let rows = [
            SQLiteEngramServiceReadProvider.ReplayFTSRow(rowid: 10, content: "User: inspect the logs"),
            SQLiteEngramServiceReadProvider.ReplayFTSRow(rowid: 11, content: "Assistant: found the timeout"),
            SQLiteEngramServiceReadProvider.ReplayFTSRow(rowid: 12, content: "tool output goes here"),
        ]

        let entries = SQLiteEngramServiceReadProvider.replayEntries(
            from: rows,
            source: "codex",
            limit: 2
        )

        XCTAssertEqual(entries.map(\.index), [0, 1])
        XCTAssertEqual(entries.map(\.role), ["user", "assistant"])
        XCTAssertEqual(entries.map(\.preview), ["inspect the logs", "found the timeout"])
    }

    func testSQLiteReplayTimelineDoesNotDelegateToEmptyFileSystemStub() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceReadProvider.swift")
        let start = try XCTUnwrap(source.range(of: "func replayTimeline(_ request: EngramServiceReplayTimelineRequest) async throws -> EngramServiceReplayTimelineResponse", options: [], range: source.range(of: "struct SQLiteEngramServiceReadProvider")!.lowerBound..<source.endIndex))
        let end = try XCTUnwrap(source.range(of: "func resumeCommand(", options: [], range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(body.contains("fileSystemProvider.replayTimeline"))
        XCTAssertTrue(body.contains("sessions_fts"))
    }

    func testServiceSearchDrivesLatinQueriesFromFtsMatches() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceReadProvider.swift")
        let start = try XCTUnwrap(source.range(of: "let termMatches = CJKText.ftsMatchTerms(tokens)"))
        let end = try XCTUnwrap(source.range(of: "let rows = try Row.fetchAll", options: [], range: start.lowerBound..<source.endIndex))
        let latinPath = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(latinPath.contains("WITH"))
        XCTAssertTrue(latinPath.contains("JOIN sessions s ON s.id ="))
        XCTAssertFalse(
            latinPath.contains("AND EXISTS"),
            "Latin FTS search must not run a correlated MATCH probe for every sessions row"
        )
        XCTAssertFalse(
            latinPath.contains("session_id = s.id"),
            "Latin FTS search must drive from MATCH results before joining sessions"
        )
    }

    func testSnapshotUpsertPreservesGeneratedSummaryForEquivalentReindex() throws {
        let source = try serviceCoreSource("EngramCoreWrite/Indexing/SessionSnapshotWriter.swift")
        let start = try XCTUnwrap(source.range(of: "summary = CASE"))
        let end = try XCTUnwrap(source.range(of: "size_bytes = excluded.size_bytes", options: [], range: start.lowerBound..<source.endIndex))
        let summaryUpsert = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(summaryUpsert.contains("sessions.summary_message_count >= excluded.summary_message_count"))
        XCTAssertTrue(summaryUpsert.contains("THEN sessions.summary"))
        XCTAssertTrue(summaryUpsert.contains("THEN sessions.summary_message_count"))
        XCTAssertTrue(summaryUpsert.contains("ELSE COALESCE(excluded.summary, sessions.summary)"))
    }

    func testServiceAIHTTPTimeoutStaysBelowIPCFrameDeadline() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceCommandHandler.swift")
        XCTAssertTrue(
            source.contains("private static let aiChatTimeoutSeconds: TimeInterval = 20")
                || source.contains("aiChatTimeoutSeconds: TimeInterval = 20"),
            "AI summary/title requests must fail before the 30s IPC frame deadline so the service cannot write after the client times out"
        )
        XCTAssertTrue(source.contains("request.timeoutInterval = aiChatTimeoutSeconds"))
        XCTAssertFalse(source.contains("request.timeoutInterval = 45"))
    }

    func testServiceTranscriptFallbackDoesNotBypassAdapterSizeFailures() throws {
        let source = try serviceCoreSource("EngramService/Core/TranscriptExportService.swift")
        let start = try XCTUnwrap(source.range(of: "static func readMessages(filePath: String, source: String)"))
        let end = try XCTUnwrap(source.range(of: "private static func adapterSourceName", options: [], range: start.lowerBound..<source.endIndex))
        let reader = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(reader.contains("try await readWithAdapterRegistry"))
        XCTAssertTrue(reader.contains("try TranscriptSizeGuard.validateFullJSONTranscript"))
        XCTAssertTrue(reader.contains("isFallbackUnsafeParserFailure"))
        XCTAssertTrue(reader.contains("catch let failure as ParserFailure where isFallbackUnsafeParserFailure(failure)"))
    }

    func testRecordSessionAccessUpdatesAccessColumnsThroughWriteGate() async throws {
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
        try await client.recordSessionAccess(sessionId: "s1")
        try await client.recordSessionAccess(sessionId: "s1")

        let queue = try DatabaseQueue(path: paths.database.path)
        let row = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT access_count, last_accessed_at FROM sessions WHERE id = 's1'")
        }
        XCTAssertEqual(row?["access_count"] as Int?, 2)
        XCTAssertFalse((row?["last_accessed_at"] as String? ?? "").isEmpty)
    }

    func testRecordInsightAccessUpdatesAccessColumnsThroughWriteGate() async throws {
        let paths = try makeServiceIPCPaths()
        try await DatabaseQueue(path: paths.database.path).write { db in
            try db.execute(
                sql: """
                CREATE TABLE insights (
                  id TEXT PRIMARY KEY,
                  content TEXT NOT NULL,
                  wing TEXT,
                  room TEXT,
                  importance INTEGER DEFAULT 5,
                  source_session_id TEXT,
                  created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                  insight_type TEXT DEFAULT 'semantic',
                  superseded_by TEXT,
                  last_accessed_at TEXT,
                  access_count INTEGER NOT NULL DEFAULT 0
                )
                """
            )
            try db.execute(
                sql: """
                INSERT INTO insights(id, content, importance, insight_type, access_count)
                VALUES ('insight-1', 'memory access counter policy', 5, 'semantic', 0)
                """
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
        try await client.recordInsightAccess(ids: ["insight-1", "insight-1", "missing", " "])
        try await client.recordInsightAccess(ids: ["insight-1"])

        let queue = try DatabaseQueue(path: paths.database.path)
        let row = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT access_count, last_accessed_at FROM insights WHERE id = 'insight-1'")
        }
        XCTAssertEqual(row?["access_count"] as Int?, 2)
        XCTAssertFalse((row?["last_accessed_at"] as String? ?? "").isEmpty)
    }

    // Disk-audit product consumer E2E lives in EngramMCPExecutableTests
    // (get_memory lifecycle ranking) and EngramTests (DatabaseManager accessedDesc).
    // Ad-hoc DatabaseQueue ORDER BY is not a shipped consumer.

    func testSessionRelationRoundTripIsSymmetricIdempotentAndRemovable() async throws {
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

        // No relations yet (table not even created): read returns empty.
        let before = try await client.relatedSessions(sessionId: "s1")
        XCTAssertEqual(before, [])

        // add(s2, s1) — order reversed from a<b normalization on purpose.
        let added = try await client.addSessionRelation(aId: "s2", bId: "s1")
        XCTAssertTrue(added.ok)

        // Symmetric: each side sees the other.
        let s1Related = try await client.relatedSessions(sessionId: "s1")
        XCTAssertEqual(s1Related, ["s2"])
        let s2Related = try await client.relatedSessions(sessionId: "s2")
        XCTAssertEqual(s2Related, ["s1"])

        // Idempotent: a duplicate add (either order) yields exactly one row.
        let dup = try await client.addSessionRelation(aId: "s1", bId: "s2")
        XCTAssertTrue(dup.ok)
        let queue = try DatabaseQueue(path: paths.database.path)
        let rowCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_relations") ?? -1
        }
        XCTAssertEqual(rowCount, 1)

        // Self-link rejected.
        let selfLink = try await client.addSessionRelation(aId: "s1", bId: "s1")
        XCTAssertFalse(selfLink.ok)
        XCTAssertEqual(selfLink.error, "self-link")

        // Nonexistent session rejected.
        let missing = try await client.addSessionRelation(aId: "s1", bId: "does-not-exist")
        XCTAssertFalse(missing.ok)
        XCTAssertEqual(missing.error, "session-not-found")

        // remove clears it (either order resolves to the same row).
        let removed = try await client.removeSessionRelation(aId: "s2", bId: "s1")
        XCTAssertTrue(removed.ok)
        let s1After = try await client.relatedSessions(sessionId: "s1")
        XCTAssertEqual(s1After, [])
        let s2After = try await client.relatedSessions(sessionId: "s2")
        XCTAssertEqual(s2After, [])
    }

    func testSecondUnixSocketServerStartDoesNotRewriteCapabilityToken() throws {
        let paths = try makeServiceIPCPaths()
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            .success(requestId: request.requestId, result: Data("{}".utf8))
        }
        try server.start()
        defer { server.stop() }

        let tokenPath = ServiceCapabilityToken.path(forSocketPath: paths.socket.path)
        let firstToken = try String(contentsOfFile: tokenPath, encoding: .utf8)
        try server.start()
        let secondToken = try String(contentsOfFile: tokenPath, encoding: .utf8)

        XCTAssertEqual(firstToken, secondToken)
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
          "summaryStyle": "bullet points",
          "summarySampleFirst": 2,
          "summarySampleLast": 3,
          "summaryTruncateChars": 40
        }
        """.data(using: .utf8)!.write(to: settingsURL)

        let settings = EngramServiceCommandHandler.ServiceAISettings.read(
            settingsPath: settingsURL,
            keychainReader: { account in account == "aiApiKey" ? "secret" : nil }
        )

        XCTAssertEqual(settings.summaryConfig?.summaryLanguage, "English")
        XCTAssertEqual(settings.summaryConfig?.summaryMaxSentences, 5)
        XCTAssertEqual(settings.summaryConfig?.summaryStyle, "bullet points")
        XCTAssertEqual(settings.summaryConfig?.summarySampleFirst, 2)
        XCTAssertEqual(settings.summaryConfig?.summarySampleLast, 3)
        XCTAssertEqual(settings.summaryConfig?.summaryTruncateChars, 40)
    }

    func testServiceAISettingsUsesKeychainWhenSettingsFileIsMissing_repro() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-ai-missing-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")

        let settings = EngramServiceCommandHandler.ServiceAISettings.read(
            settingsPath: settingsURL,
            environment: [:],
            keychainReader: { account in account == "aiApiKey" ? "keychain-secret" : nil }
        )

        XCTAssertEqual(settings.summaryConfig?.provider, "openai")
        XCTAssertEqual(settings.summaryConfig?.model, "gpt-4o-mini")
        XCTAssertEqual(settings.summaryConfig?.apiKey, "keychain-secret")
        XCTAssertEqual(settings.titleConfig?.provider, "ollama")
    }

    func testServiceAISettingsHonorsEnvironmentSettingsPath_repro() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-ai-env-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: [
            "aiProtocol": "openai",
            "aiApiKey": "env-settings-secret",
            "aiModel": "env-settings-model",
        ]).write(to: settingsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)

        let settings = EngramServiceCommandHandler.ServiceAISettings.read(
            environment: ["ENGRAM_SETTINGS_PATH": settingsURL.path],
            keychainReader: { _ in nil }
        )

        XCTAssertEqual(settings.summaryConfig?.apiKey, "env-settings-secret")
        XCTAssertEqual(settings.summaryConfig?.model, "env-settings-model")
    }

    func testServiceAIClientSamplesTranscriptFromSummaryTuning() {
        let context = EngramServiceCommandHandler.AIContext(
            id: "sample",
            source: "codex",
            project: "engram",
            cwd: "/tmp/engram",
            messageCount: 5,
            startTime: "2026-04-23T00:00:00Z",
            nativeTitle: "Native",
            nativeSummary: "Native summary",
            transcript: [
                "first message has a long tail",
                "second message",
                "middle message should be omitted",
                "fourth message",
                "fifth message has a long tail"
            ].joined(separator: "\n")
        )
        var config = EngramServiceCommandHandler.ServiceAISettings.ChatConfig(
            provider: "openai",
            baseURL: "https://api.openai.com",
            apiKey: "secret",
            model: "gpt-4o-mini",
            maxTokens: 200,
            temperature: 0.3
        )
        config.summarySampleFirst = 1
        config.summarySampleLast = 2
        config.summaryTruncateChars = 14

        let transcript = EngramServiceCommandHandler.ServiceAIClient.boundedTranscript(
            context,
            config: config,
            limit: 1_000
        )

        XCTAssertTrue(transcript.contains("first message"))
        XCTAssertTrue(transcript.contains("fourth message"))
        XCTAssertTrue(transcript.contains("fifth message"))
        XCTAssertTrue(transcript.contains("...[2 messages omitted]..."))
        XCTAssertFalse(transcript.contains("middle message should be omitted"))
        XCTAssertFalse(transcript.contains("long tail"))
    }

    func testServiceAIClientRedactsFullTranscriptBeforeBounding_repro() {
        let key = "-----BEGIN PRIVATE KEY-----\n"
            + String(repeating: "A", count: 13_000)
            + "\n-----END PRIVATE KEY-----"
        let context = EngramServiceCommandHandler.AIContext(
            id: "redacted-prompt",
            source: "codex",
            project: "engram",
            cwd: "/tmp/engram",
            messageCount: 1,
            startTime: "2026-04-23T00:00:00Z",
            nativeTitle: "Native",
            nativeSummary: key,
            transcript: key
        )

        let bounded = EngramServiceCommandHandler.ServiceAIClient.boundedTranscript(
            context,
            limit: 12_000
        )

        XCTAssertTrue(bounded.contains(TranscriptRedactionPolicy.redactionToken), bounded)
        XCTAssertFalse(bounded.contains("BEGIN PRIVATE KEY"), bounded)
        XCTAssertFalse(bounded.contains(String(repeating: "A", count: 64)), bounded)
    }

    func testServiceAISettingsResolvesKeychainMarkerWithoutEnvironmentSecretFallback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-ai-keychain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        try """
        {
          "aiProtocol": "openai",
          "aiApiKey": "@keychain",
          "aiModel": "gpt-4o-mini"
        }
        """.data(using: .utf8)!.write(to: settingsURL)

        let resolved = EngramServiceCommandHandler.ServiceAISettings.read(
            settingsPath: settingsURL,
            environment: ["ENGRAM_KEYCHAIN_aiApiKey": "env-secret"],
            keychainReader: { account in account == "aiApiKey" ? "direct-secret" : nil }
        )
        let unresolved = EngramServiceCommandHandler.ServiceAISettings.read(
            settingsPath: settingsURL,
            environment: ["ENGRAM_KEYCHAIN_aiApiKey": "env-secret"],
            keychainReader: { _ in nil }
        )

        XCTAssertEqual(resolved.summaryConfig?.apiKey, "direct-secret")
        XCTAssertNil(unresolved.summaryConfig)
    }

    func testServiceAISettingsResolvesKeychainMarkerFromRuntimeSecretBridge() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-ai-secret-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        try """
        {
          "aiProtocol": "openai",
          "aiApiKey": "@keychain",
          "titleProvider": "openai",
          "titleApiKey": "@keychain",
          "aiModel": "gpt-4o-mini"
        }
        """.data(using: .utf8)!.write(to: settingsURL)
        let bridgeURL = directory.appendingPathComponent("ai-secrets.json")
        try #"{"aiApiKey":"summary-secret","titleApiKey":"title-secret"}"#
            .data(using: .utf8)!
            .write(to: bridgeURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bridgeURL.path)

        let settings = EngramServiceCommandHandler.ServiceAISettings.read(
            settingsPath: settingsURL,
            environment: ["ENGRAM_RUNTIME_AI_SECRETS_PATH": bridgeURL.path],
            keychainReader: { _ in nil }
        )

        XCTAssertEqual(settings.summaryConfig?.apiKey, "summary-secret")
        XCTAssertEqual(settings.titleConfig?.apiKey, "title-secret")
    }

    func testServiceAISettingsPrefersFreshKeychainOverStaleBridgeAndPlaintext_repro() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-ai-secret-precedence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        try #"{"aiProtocol":"openai","aiApiKey":"stale-plaintext","aiModel":"gpt-4o-mini"}"#
            .data(using: .utf8)!
            .write(to: settingsURL)
        let bridgeURL = directory.appendingPathComponent("ai-secrets.json")
        try #"{"aiApiKey":"stale-bridge"}"#.data(using: .utf8)!.write(to: bridgeURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bridgeURL.path)

        let settings = EngramServiceCommandHandler.ServiceAISettings.read(
            settingsPath: settingsURL,
            environment: ["ENGRAM_RUNTIME_AI_SECRETS_PATH": bridgeURL.path],
            keychainReader: { account in account == "aiApiKey" ? "fresh-keychain" : nil }
        )

        XCTAssertEqual(settings.summaryConfig?.apiKey, "fresh-keychain")
    }

    func testServiceAISettingsRejectsSymlinkRuntimeSecretBridge_repro() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-ai-secret-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        try #"{"aiApiKey":"@keychain","aiModel":"gpt-4o-mini"}"#
            .data(using: .utf8)!
            .write(to: settingsURL)
        let outside = directory.appendingPathComponent("outside-secrets.json")
        try #"{"aiApiKey":"linked-secret"}"#.data(using: .utf8)!.write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
        let bridgeURL = directory.appendingPathComponent("ai-secrets.json")
        try FileManager.default.createSymbolicLink(atPath: bridgeURL.path, withDestinationPath: outside.path)

        let settings = EngramServiceCommandHandler.ServiceAISettings.read(
            settingsPath: settingsURL,
            environment: ["ENGRAM_RUNTIME_AI_SECRETS_PATH": bridgeURL.path],
            keychainReader: { _ in nil }
        )

        XCTAssertNil(settings.summaryConfig)
    }

    func testAIChatURLDoesNotDoubleV1Path() throws {
        let url = try EngramServiceCommandHandler.ServiceAIClient.chatCompletionsURL(
            baseURL: "https://token-plan-sgp.xiaomimimo.com/v1"
        )
        XCTAssertEqual(url.absoluteString, "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions")
    }

    func testServiceAISettingsReadsLegacySwiftTitleBaseURLAndKeychainResolver() throws {
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
            keychainReader: { account in account == "titleApiKey" ? "secret" : nil }
        )

        XCTAssertEqual(settings.titleConfig?.baseURL, "https://token-plan-sgp.xiaomimimo.com")
        XCTAssertEqual(settings.titleConfig?.apiKey, "secret")
        XCTAssertEqual(settings.titleConfig?.model, "mimo-v2.5-pro")
        XCTAssertEqual(settings.titleConfig?.maxTokens, 120)
    }

    func testServiceAISettingsAcceptsKeylessOllamaTitleProvider() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-ai-ollama-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        try """
        {
          "titleProvider": "ollama",
          "titleBaseURL": "http://localhost:11434",
          "titleModel": "qwen2.5:3b"
        }
        """.data(using: .utf8)!.write(to: settingsURL)

        let settings = EngramServiceCommandHandler.ServiceAISettings.read(
            settingsPath: settingsURL,
            keychainReader: { _ in nil }
        )

        XCTAssertEqual(settings.titleConfig?.provider, "ollama")
        XCTAssertEqual(settings.titleConfig?.baseURL, "http://localhost:11434")
        XCTAssertEqual(settings.titleConfig?.apiKey, "")
        XCTAssertEqual(settings.titleConfig?.model, "qwen2.5:3b")
    }

    func testServiceAISettingsIgnoresStoredTitleApiKeyForOllamaTitleProvider() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-ai-ollama-stored-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        try """
        {
          "titleProvider": "ollama",
          "titleBaseURL": "http://localhost:11434",
          "titleApiKey": "@keychain",
          "titleModel": "qwen2.5:3b"
        }
        """.data(using: .utf8)!.write(to: settingsURL)

        let settings = EngramServiceCommandHandler.ServiceAISettings.read(
            settingsPath: settingsURL,
            keychainReader: { account in account == "titleApiKey" ? "stored-cloud-title-key" : nil }
        )

        XCTAssertEqual(settings.titleConfig?.provider, "ollama")
        XCTAssertEqual(settings.titleConfig?.apiKey, "")
    }

    func testServiceAISettingsAcceptsKeylessCustomTitleProvider() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-ai-custom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        try """
        {
          "titleProvider": "custom",
          "titleBaseURL": "http://127.0.0.1:8080",
          "titleModel": "local-title"
        }
        """.data(using: .utf8)!.write(to: settingsURL)

        let settings = EngramServiceCommandHandler.ServiceAISettings.read(
            settingsPath: settingsURL,
            keychainReader: { _ in nil }
        )

        XCTAssertEqual(settings.titleConfig?.provider, "custom")
        XCTAssertEqual(settings.titleConfig?.apiKey, "")
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

    func testClearParentSessionResetsNonSubagentSkipTier() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceCommandHandler.swift")
        let start = try XCTUnwrap(source.range(of: "private static func clearParentSession"))
        let end = try XCTUnwrap(source.range(of: "private static func dismissSuggestion"))
        let clearSource = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(clearSource.contains("tier = CASE"))
        // Wave 7B H05: subagent AND dispatched keep skip across clearParent.
        XCTAssertTrue(
            clearSource.contains("WHEN agent_role IN ('subagent', 'dispatched') THEN 'skip'")
                || clearSource.contains("WHEN agent_role = 'subagent' OR agent_role = 'dispatched' THEN 'skip'"),
            "manual unlink must preserve skip for subagent and dispatched agents"
        )
        XCTAssertTrue(
            clearSource.contains("ELSE NULL"),
            "manual unlink must re-evaluate ordinary (non-agent) children"
        )
    }

    func testProjectMigrationCommandsEmitServiceLogs() throws {
        let migrationSource = try serviceCoreSource("EngramService/Core/EngramServiceCommandHandler+ProjectMigration.swift")
        let dispatchSource = try serviceCoreSource("EngramService/Core/EngramServiceCommandHandler.swift")

        for command in ["projectMove", "projectArchive", "projectUndo", "projectMoveBatch"] {
            XCTAssertTrue(migrationSource.contains("\"\(command) requested"), "\(command) must log entry")
            XCTAssertFalse(
                dispatchSource.contains("\"\(command) finished"),
                "request waiter must not own \(command) terminal success logging"
            )
        }
        XCTAssertTrue(migrationSource.contains("logProjectMigrationSuccess(commandName:"))
        XCTAssertTrue(migrationSource.contains("logProjectMigrationFailure(commandName:"))
        XCTAssertFalse(dispatchSource.contains("logProjectMigrationFailure(command:"))
    }

    func testProjectMoveResultPayloadIsCappedBelowFrameLimit() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceCommandHandler+ProjectMigration.swift")
        let start = try XCTUnwrap(source.range(of: "private static func mapPipelineResult"))
        let end = try XCTUnwrap(source.range(of: "private static func encodeBatchResult", options: [], range: start.lowerBound..<source.endIndex))
        let mapper = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(source.contains("private static let projectMovePayloadListLimit"))
        XCTAssertTrue(source.contains("private static let projectMovePayloadStringLimit"))
        XCTAssertTrue(source.contains("private static func cappedProjectMoveString"))
        XCTAssertTrue(mapper.contains(".prefix(Self.projectMovePayloadListLimit)"))
        XCTAssertTrue(mapper.contains("Self.cappedProjectMoveString"))
        XCTAssertFalse(mapper.contains("own: result.review.own,\n            other: result.review.other"))
        XCTAssertFalse(mapper.contains("porcelain: result.git.porcelain"))
    }

    func testProjectMoveCompensationOnlyRevertsCompletedPhysicalMove() throws {
        let source = try serviceCoreSource("EngramCoreWrite/ProjectMove/Orchestrator.swift")

        XCTAssertTrue(source.contains("var physicalMoveApplied = false"))
        XCTAssertTrue(source.contains("physicalMoveApplied = true"))
        XCTAssertTrue(source.contains("physicalMoveApplied: physicalMoveApplied"))
        XCTAssertTrue(source.contains("if physicalMoveApplied {"))
        XCTAssertTrue(source.contains("attemptedDst may be a pre-existing user directory"))
    }

    func testProjectMoveUpdatesGeminiProjectsJsonForSameSlugMove() throws {
        let source = try serviceCoreSource("EngramCoreWrite/ProjectMove/Orchestrator.swift")
        let start = try XCTUnwrap(source.range(of: "let geminiDirTouched ="))
        let end = try XCTUnwrap(source.range(of: "// Step 3: patch JSONL", options: [], range: start.lowerBound..<source.endIndex))
        let geminiApply = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(geminiApply.contains("skippedDirs.contains"))
        XCTAssertTrue(geminiApply.contains("$0.sourceId == .geminiCli && $0.reason == .noop"))
        XCTAssertTrue(geminiApply.contains("plan.oldEntry != nil || geminiDirTouched"))
        XCTAssertTrue(geminiApply.contains("GeminiProjectsJSON.apply(plan: plan)"))
    }

    func testRunnerStartupScanUsesAllEnabledAdapters() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")

        // Feature #2 slice B — startup ingests every adapter EXCEPT user-disabled
        // sources, which are filtered out of defaultAdapters() at scan time.
        XCTAssertTrue(source.contains("SessionAdapterFactory.defaultAdapters()"))
        XCTAssertTrue(source.contains("let enabledAdapters = adaptersExcludingDisabled("))
        XCTAssertTrue(source.contains("disabledSources: disabled"))
        XCTAssertTrue(source.contains("let startupAdapters = enabledAdapters"))
        XCTAssertFalse(
            source.contains(": SessionAdapterFactory.recentActiveAdapters()"),
            "startup scan must not skip sessions solely because they are older than the recent-active window"
        )
        // Archive V2 projects the two exact-source adapters to the locators
        // captured in this cycle before any parser-facing startup phase runs.
        // With the feature disabled, `parserAdapters` is assigned exactly the
        // full enabled startup set. Keeping it immutable after branch selection
        // also makes subsequent @Sendable write-gate captures race-free.
        XCTAssertTrue(source.contains("let parserAdapters: [any SessionAdapter]"))
        XCTAssertTrue(source.contains("parserAdapters = startupAdapters"))
        XCTAssertTrue(source.contains("SessionAdapterFactory.indexingAdapters("))
        XCTAssertTrue(source.contains("indexer: WriterStartupIndexing("))
        XCTAssertTrue(source.contains("adapters: parserAdapters"))
        XCTAssertTrue(source.contains("excludedSnapshotSources: excludedSnapshotSources"))
    }

    func testArchiveDrainerResolvesProfileAdaptersInsideEveryPass() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        XCTAssertTrue(
            source.contains("await archiveV2Coordinator.requestFullCaptureSweep()"),
            "service restart must rebuild exact-index retry scheduling from durable capture state"
        )
        let start = try XCTUnwrap(
            source.range(of: "let drainer = ArchiveV2BacklogDrainer")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "await archiveV2Coordinator.attachDrainer(drainer)",
                range: start.lowerBound ..< source.endIndex
            )
        )
        let composition = String(source[start.lowerBound ..< end.lowerBound])

        XCTAssertTrue(composition.contains("adapterProvider: {"))
        XCTAssertTrue(
            composition.contains("Self.exactArchiveAdaptersForBacklogPass(environment: environment)"),
            "backlog adapterProvider must reread disabled sources each pass (SRC-001)"
        )
        XCTAssertFalse(
            composition.contains("let disabledSources = Self.readDisabledSources"),
            "must not capture a startup disabledSources snapshot outside the pass closure"
        )

        let coordinator = try serviceCoreSource("EngramService/Core/ArchiveV2ServiceCoordinator.swift")
        let provider = try XCTUnwrap(coordinator.range(of: "let adapters = adapterProvider()"))
        let refreshSnapshot = try XCTUnwrap(
            coordinator.range(
                of: "let consumedRefreshRequestID = fullCaptureRefreshRequestID",
                range: provider.upperBound ..< coordinator.endIndex
            )
        )
        let firstDrainerAwait = try XCTUnwrap(
            coordinator.range(
                of: "await drainer?.setActiveStages",
                range: provider.upperBound ..< coordinator.endIndex
            )
        )

        XCTAssertLessThan(provider.lowerBound, refreshSnapshot.lowerBound)
        XCTAssertLessThan(
            refreshSnapshot.lowerBound,
            firstDrainerAwait.lowerBound,
            "adapter and refresh-generation snapshots must be atomic with respect to actor suspension"
        )
    }

    func testRunnerRepoDiscoveryProbesOutsideWriteGate() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")

        XCTAssertTrue(source.contains("RepoDiscovery.sessionCwdCounts"))
        XCTAssertTrue(source.contains("RepoDiscovery.probeRepositories"))
        XCTAssertTrue(source.contains("RepoDiscovery.upsert"))
        XCTAssertFalse(source.contains("writer.write { db in try RepoDiscovery.discover(db) }"))
    }

    func testRunnerRefreshesRepoCountsWhenProbeCooldownHasNoDueCandidates_repro() async throws {
        let paths = try makeServiceIPCPaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime
        )
        _ = try await gate.performWriteCommand(name: "seedRepoCountRefresh") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions(id, source, start_time, cwd, file_path, tier)
                    VALUES ('repo-count-1', 'codex', '2026-08-22T00:00:00Z',
                            '/work/recount', '/tmp/repo-count-1.jsonl', 'normal')
                    """)
            }
        }
        let clock = RunnerRepoClock()
        let throttle = RepoDiscoveryMaintenanceThrottle(
            batchLimit: 32,
            cooldown: 21_600,
            now: { clock.now }
        )
        let probeCalls = LockedCounter()
        let probe: @Sendable (String) -> GitRepoProbe? = { cwd in
            probeCalls.increment()
            return GitRepoProbe(
                path: cwd,
                name: "recount",
                branch: "main",
                dirtyCount: 0,
                untrackedCount: 0,
                unpushedCount: 0,
                lastCommitHash: nil,
                lastCommitMsg: nil,
                lastCommitAt: nil
            )
        }

        _ = try await EngramServiceRunner.refreshRepoDiscovery(
            gate: gate,
            throttle: throttle,
            probe: probe,
            phaseName: "repoCountRepro"
        )
        _ = try await gate.performWriteCommand(name: "insertRepoCountSecondSession") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions(id, source, start_time, cwd, file_path, tier)
                    VALUES ('repo-count-2', 'codex', '2026-08-22T00:01:00Z',
                            '/work/recount', '/tmp/repo-count-2.jsonl', 'normal')
                    """)
            }
        }

        _ = try await EngramServiceRunner.refreshRepoDiscovery(
            gate: gate,
            throttle: throttle,
            probe: probe,
            phaseName: "repoCountRepro"
        )
        let count = try await gate.performReadCommand(name: "readRepoCount") { writer in
            try writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT session_count FROM git_repos WHERE path = '/work/recount'"
                ) ?? 0
            }
        }.value

        XCTAssertEqual(probeCalls.value, 1, "the second cycle must be inside metadata-probe cooldown")
        XCTAssertEqual(count, 2, "count refresh must run even when no git probe is due")
    }

    func testRunnerReprobesVisibleCwdWhenRepoRowDisappearsDuringCooldown_repro() async throws {
        let paths = try makeServiceIPCPaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime
        )
        _ = try await gate.performWriteCommand(name: "seedMissingRepoRefresh") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions(id, source, start_time, cwd, file_path, tier)
                    VALUES ('missing-repo', 'codex', '2026-08-23T00:00:00Z',
                            '/work/missing-repo', '/tmp/missing-repo.jsonl', 'normal')
                    """)
            }
        }
        let clock = RunnerRepoClock()
        let throttle = RepoDiscoveryMaintenanceThrottle(
            batchLimit: 32,
            cooldown: 21_600,
            now: { clock.now }
        )
        let probeCalls = LockedCounter()
        let probe: @Sendable (String) -> GitRepoProbe? = { cwd in
            probeCalls.increment()
            return GitRepoProbe(
                path: cwd,
                name: "missing-repo",
                branch: "main",
                dirtyCount: 0,
                untrackedCount: 0,
                unpushedCount: 0,
                lastCommitHash: nil,
                lastCommitMsg: nil,
                lastCommitAt: nil
            )
        }

        _ = try await EngramServiceRunner.refreshRepoDiscovery(
            gate: gate,
            throttle: throttle,
            probe: probe,
            phaseName: "missingRepoRepro"
        )
        _ = try await gate.performWriteCommand(name: "removeRepoIdentity") { writer in
            try writer.write { db in
                try db.execute(sql: "DELETE FROM git_repos WHERE path = '/work/missing-repo'")
            }
        }
        _ = try await EngramServiceRunner.refreshRepoDiscovery(
            gate: gate,
            throttle: throttle,
            probe: probe,
            phaseName: "missingRepoRepro"
        )

        let repoCount = try await gate.performReadCommand(name: "readRecreatedRepo") { writer in
            try writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM git_repos WHERE path = '/work/missing-repo'"
                ) ?? 0
            }
        }.value
        XCTAssertEqual(probeCalls.value, 2, "a missing repo identity must bypass the cwd cooldown")
        XCTAssertEqual(repoCount, 1)
    }

    func testRunnerPeriodicScanDoesNotCompeteWithStartupScanImmediately() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")

        XCTAssertFalse(
            source.contains("var isFirstScan = true"),
            "Periodic indexing must not run an immediate first scan while startup maintenance already holds the write gate"
        )
        // Wave 7C S01: NSBackgroundActivityScheduler performs work *inside* the
        // activity (completion only after index cycle), not an immediate first scan.
        XCTAssertTrue(
            source.contains("NSIndexingBackgroundActivityScheduler")
                || source.contains("performWhenDue"),
            "periodic loop must use background activity scheduling, not an immediate first scan"
        )
        XCTAssertTrue(
            source.contains("performWhenDue("),
            "must schedule via performWhenDue so OS completion waits for work"
        )
        XCTAssertTrue(
            source.contains("runOnePeriodicIndexCycle")
                || source.contains("indexRecent"),
            "scan work must live under the activity work closure"
        )
    }

    // EMB-STARVE: an idle merge-only scan must still drain existing session
    // or insight embedding work instead of waiting for a future merge/restart.
    func testRunnerPeriodicEmbeddingBackfillChecksBacklogOnIdleScan_repro() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let cycleStart = try XCTUnwrap(source.range(of: "runOnePeriodicIndexCycle"))
        let cycleBody = String(source[cycleStart.lowerBound...])

        XCTAssertTrue(
            cycleBody.contains("shouldRunEmbeddingBackfill = try await hasPendingEmbeddingBackfill(gate: gate)")
                && cycleBody.contains("if shouldRunEmbeddingBackfill {")
                && cycleBody.contains("periodicSessionEmbeddingBackfill")
                && cycleBody.contains("periodicInsightEmbeddingBackfill"),
            "idle periodic scans must use an embedding-backlog signal independent of scan.indexed"
        )
    }

    func testPeriodicEmbeddingBacklogDetectsSessionAndInsightWork_repro() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            queueTimeoutNanoseconds: 20_000_000
        )
        _ = try await gate.performWriteCommand(name: "seedEmbeddingBacklog") { writer in
            try writer.migrate()
        }

        let initiallyPending = try await EngramServiceRunner.hasPendingEmbeddingBackfill(gate: gate)
        XCTAssertFalse(initiallyPending)

        _ = try await gate.performWriteCommand(name: "seedSessionEmbeddingBacklog") { writer in
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (id, source, start_time, file_path, tier)
                    VALUES ('idle-session', 'codex', '2026-07-19T00:00:00Z', '/tmp/idle.jsonl', 'normal')
                    """)
                try db.execute(sql: """
                    INSERT INTO sessions_fts(session_id, content)
                    VALUES ('idle-session', 'idle session pending embedding work')
                    """)
                try db.execute(sql: """
                    INSERT INTO session_index_jobs
                      (id, session_id, job_kind, target_sync_version, status, retry_count)
                    VALUES ('idle-job', 'idle-session', 'embedding', 1, 'failed_retryable', 1)
                    """)
            }
        }
        let hasSessionBacklog = try await EngramServiceRunner.hasPendingEmbeddingBackfill(gate: gate)
        XCTAssertTrue(hasSessionBacklog)

        _ = try await gate.performWriteCommand(name: "replaceWithInsightEmbeddingBacklog") { writer in
            try writer.write { db in
                try db.execute(sql: "DELETE FROM session_index_jobs WHERE id = 'idle-job'")
                try db.execute(sql: """
                    INSERT INTO insights (id, content, importance)
                    VALUES ('idle-insight', 'idle insight pending embedding work', 5)
                    """)
                try db.execute(sql: """
                    INSERT INTO insight_embedding_failures
                      (insight_id, retry_count, status, last_error)
                    VALUES ('idle-insight', 1, 'failed_retryable', 'transient')
                    """)
            }
        }
        let hasInsightBacklog = try await EngramServiceRunner.hasPendingEmbeddingBackfill(gate: gate)
        XCTAssertTrue(hasInsightBacklog)
    }

    func testPeerDisconnectCancelsInFlightHandler_repro() async throws {
        // Wave 7C H03: client socket close must cancel the server handler task
        // (not only server.stop()), so Task.isCancelled flips mid-command.
        let paths = try makeServiceIPCPaths()
        let requestStarted = expectation(description: "handler started")
        let handlerCancelled = expectation(description: "handler saw cancellation")
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            requestStarted.fulfill()
            for _ in 0..<200 {
                if Task.isCancelled {
                    handlerCancelled.fulfill()
                    return .failure(
                        requestId: request.requestId,
                        error: EngramServiceErrorEnvelope(
                            name: "Cancelled",
                            message: "peer disconnect cancel",
                            retryPolicy: "never"
                        )
                    )
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTFail("peer disconnect must cancel the in-flight handler")
            return .failure(
                requestId: request.requestId,
                error: EngramServiceErrorEnvelope(
                    name: "Timeout",
                    message: "handler completed without cancel",
                    retryPolicy: "never"
                )
            )
        }
        try server.start()
        defer { server.stop() }

        // Raw framed request then immediate close (simulates client timeout).
        let fd = try UnixSocketEngramServiceTransport.connectSocket(path: paths.socket.path)
        let body = try JSONEncoder().encode(EngramServiceRequestEnvelope(command: "status"))
        try UnixSocketEngramServiceTransport.writeFrame(body, to: fd)

        await fulfillment(of: [requestStarted], timeout: 2)
        // Client abandons the connection without reading the response.
        shutdown(fd, SHUT_RDWR)
        close(fd)

        await fulfillment(of: [handlerCancelled], timeout: 3)
    }

    func testRunnerPeriodicScanUsesEnabledAdapters() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        // Cycle body lives in runOnePeriodicIndexCycle (under performWhenDue work).
        let start = try XCTUnwrap(
            source.range(of: "private static func runOnePeriodicIndexCycle(")
                ?? source.range(of: "private static func runIndexingLoop(")
        )
        let end = try XCTUnwrap(source.range(of: "static func runInitialScan(", options: [], range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("let disabled = readDisabledSources(environment: environment)"))
        XCTAssertTrue(body.contains("let recentAdapters = await recentAdaptersForPeriodicCycle("))
        XCTAssertTrue(body.contains("archiveV2Coordinator: archiveV2Coordinator"))
        XCTAssertTrue(body.contains("disabledSources: disabled"))
        XCTAssertTrue(body.contains("let captureInputs = await archiveCaptureInputsForPeriodicCycle("))
        XCTAssertTrue(body.contains("try await writer.indexRecentSessions("))
        XCTAssertTrue(body.contains("excludedSnapshotSources: excludedSnapshotSources"))
        XCTAssertTrue(body.contains("let enabledAdapters = adaptersExcludingDisabled("))
        XCTAssertTrue(body.contains("drainRecoverableFtsJobs("))
        XCTAssertTrue(body.contains("adapters: enabledAdapters"))
        XCTAssertTrue(source.contains("IndexJobRunner(writer: writer, adapters: adapters)"))
        XCTAssertFalse(
            body.contains("try await writer.indexRecentSessions()"),
            "periodic indexing must honor disabled/default-off archived sources"
        )
        XCTAssertFalse(
            body.contains("IndexJobRunner(writer: writer).runRecoverableJobsOnce()"),
            "periodic FTS drain must not process disabled/default-off archived sources"
        )
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
        XCTAssertTrue(source.contains(#"performWriteCommand(name: "initialInstructionBackfill")"#))
        XCTAssertTrue(source.contains(#"performWriteCommand(name: "initialScanBackfills")"#))
        XCTAssertTrue(source.contains(#"performWriteCommand(name: "initialScanOrphans")"#))
    }

    func testServiceMainCancelsRunnerOnTerminationSignals() throws {
        let source = try serviceCoreSource("EngramService/main.swift")

        XCTAssertTrue(source.contains("signal(SIGTERM, SIG_IGN)"))
        XCTAssertTrue(source.contains("signal(SIGINT, SIG_IGN)"))
        XCTAssertTrue(source.contains("DispatchSource.makeSignalSource(signal: SIGTERM"))
        XCTAssertTrue(source.contains("DispatchSource.makeSignalSource(signal: SIGINT"))
        XCTAssertTrue(source.contains("serviceTask.cancel()"))
        XCTAssertTrue(source.contains("exit(0)"), "main must exit after EngramServiceRunner.run returns from graceful cancellation")
    }

    func testRunnerInitialScanPhasesAreFaultIsolatedAndRetryWriterBusy() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let start = try XCTUnwrap(source.range(of: "static func runInitialScan("))
        let end = try XCTUnwrap(source.range(of: "@discardableResult", options: [], range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        for phase in [
            "usageParserBackfillCheck",
            "initialInstructionBackfill",
            "initialScanIndex",
            "initialScanBackfills",
            "initialScanOrphans",
            "initialFtsDrain",
            "usageParserBackfillMark"
        ] {
            XCTAssertTrue(
                body.contains("runInitialScanPhase(") && body.contains(#"name: "\#(phase)""#),
                "\(phase) must be isolated so one startup-maintenance failure does not abort the rest of the launch"
            )
        }
        XCTAssertTrue(source.contains("isWriterBusy(error)"))
        XCTAssertTrue(source.contains("retrying startup phase"))
        XCTAssertTrue(source.contains("startup phase failed"))
    }

    /// L01: fatal/ready/checkpoint stdout lines must use structured encoding, not string interpolation of errors.
    func testRunnerStdoutEventsUseStructuredJSONEncoderNotInterpolation() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        XCTAssertFalse(
            source.contains(#"writeStdoutLine(#"{"event":"fatal""#),
            "fatal events must not interpolate error text into JSON"
        )
        XCTAssertFalse(
            source.contains(#"writeStdoutLine(#"{"event":"ready""#),
            "ready events must not interpolate socket paths into raw JSON strings"
        )
        XCTAssertFalse(
            source.contains(#"writeStdoutLine(#"{"event":"checkpoint""#),
            "checkpoint events must not interpolate error text into JSON"
        )
        XCTAssertTrue(source.contains("encodeStdoutJSON(") || source.contains("emit(Service"))
        XCTAssertTrue(source.contains("ServiceFatalEvent") || source.contains("event: \"fatal\""))
        XCTAssertTrue(source.contains("ServiceReadyEvent") || source.contains("event: \"ready\""))
        XCTAssertTrue(source.contains("ServiceCheckpointEvent") || source.contains("event: \"checkpoint\""))
    }

    func testRunnerBackfillsInstructionSignalsBeforeHeavyStartupIndex() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let start = try XCTUnwrap(source.range(of: "static func runInitialScan("))
        let end = try XCTUnwrap(source.range(of: "private static func elapsedMs", options: [], range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        let instruction = try XCTUnwrap(body.range(of: #"name: "initialInstructionBackfill""#))
        let index = try XCTUnwrap(body.range(of: #"name: "initialScanIndex""#))
        XCTAssertLessThan(
            instruction.lowerBound,
            index.lowerBound,
            "instruction signal backfill must run before the heavy startup index so default visibility tightens quickly on existing local history"
        )
    }

    func testRunnerInitialScanFullBackfillsWhenUsageParserVersionChanges() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        XCTAssertTrue(source.contains(#"performWriteCommand(name: "usageParserBackfillCheck")"#))
        XCTAssertTrue(source.contains("UsageParserBackfillPolicy.needsBackfill"))
        XCTAssertTrue(source.contains("let startupAdapters = enabledAdapters"))
        XCTAssertTrue(source.contains(#"performWriteCommand(name: "usageParserBackfillMark")"#))
        XCTAssertTrue(source.contains("UsageParserBackfillPolicy.markComplete"))
    }

    func testUsageParserVersionForcesKnownFileReparseBeforeMarkingComplete_repro() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let start = try XCTUnwrap(source.range(of: "static func runInitialScan("))
        let end = try XCTUnwrap(
            source.range(of: "private static func elapsedMs", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(
            source.contains("forceReparseKnownFiles: usageParserBackfillNeeded"),
            "a parser-version change must bypass unchanged-file indexing decisions"
        )
        XCTAssertTrue(
            body.contains("if usageParserBackfillNeeded && coreIndexSucceeded"),
            "the parser version must only be marked complete after the forced index phase succeeds"
        )
    }

    func testRunnerInitialScanSchedulesInsightEmbeddingBackfillOutsideMainWritePhases() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let start = try XCTUnwrap(source.range(of: "static func runInitialScan("))
        let end = try XCTUnwrap(source.range(of: "private static func elapsedMs", options: [], range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("initialInsightEmbeddingBackfill"))
        XCTAssertTrue(body.contains("runInsightEmbeddingBackfillBestEffort("))
        XCTAssertFalse(
            body.contains(#"performWriteCommand(name: "initialInsightEmbeddingBackfill") { writer in"#),
            "embedding provider I/O must not run inside one long write-gate closure"
        )
    }

    func testRunnerPeriodicScanSchedulesInsightEmbeddingBackfill() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let start = try XCTUnwrap(source.range(of: "static func runIndexingLoop("))
        let end = try XCTUnwrap(source.range(of: "/// V2 composition root", options: [], range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("periodicInsightEmbeddingBackfill"))
        XCTAssertTrue(body.contains("runInsightEmbeddingBackfillBestEffort("))
    }

    func testRunnerObservabilityRetentionLogsZeroRowCompletion() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let start = try XCTUnwrap(source.range(of: "private static func runObservabilityRetention"))
        let end = try XCTUnwrap(source.range(of: "static func runIndexingLoop"))
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

    func testRunnerPeriodicScanDrainsParentBackfillsWhenIndexIsIdle_repro() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let start = try XCTUnwrap(source.range(of: "private static func runOnePeriodicIndexCycle("))
        let end = try XCTUnwrap(
            source.range(of: "private final class IndexingScheduleBox", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])
        let parentBackfill = try XCTUnwrap(body.range(of: #"performWriteCommand(name: "periodicParentBackfills")"#))
        let prefix = String(body[..<parentBackfill.lowerBound])

        XCTAssertFalse(
            prefix.hasSuffix("if scan.indexed > 0 {\n                _ = try await gate."),
            "queued suggested parents must drain even when the current file scan is idle"
        )
        XCTAssertTrue(body.contains("refreshRepoDiscovery("))
    }

    func testSuccessfulPeriodicScanRemainsHealthyWhenMaintenanceThrows_repro() async {
        let monitor = ServiceStatusMonitor(
            staleAfter: 600,
            now: { Date(timeIntervalSince1970: 200) }
        )
        let telemetry = ServiceTelemetryCollector()
        let completion = PeriodicScanCompletionProbe()
        await monitor.recordScanFailure("old failure", at: Date(timeIntervalSince1970: 100))

        let completed = await EngramServiceRunner.runPeriodicPostIndexMaintenance {
            throw NSError(domain: "EngramServiceIPCTests", code: 1)
        } onSuccess: { (_: Int?) in
            await monitor.recordScanSuccess()
            await telemetry.recordScan(durationMs: 5, indexed: 3, total: 42)
            await completion.recordEvent()
        }

        XCTAssertTrue(completed)
        let eventCount = await completion.eventCount()
        let telemetrySnapshot = await telemetry.snapshot()
        XCTAssertEqual(eventCount, 1)
        XCTAssertEqual(telemetrySnapshot.scanCount, 1)
        let status = await monitor.status(
            indexStatus: EngramDatabaseIndexStatus(total: 42, todayParents: 7)
        )
        XCTAssertEqual(
            status,
            .running(
                total: 42,
                todayParents: 7,
                nextScanIntervalSeconds: nil,
                lastScanAt: "1970-01-01T00:03:20Z"
            )
        )
    }

    func testCancelledPeriodicMaintenanceDoesNotRunSuccessfulScanCompletion_repro() async {
        let started = CheckpointTestSignal()
        let release = CheckpointTestSignal()
        let completion = PeriodicScanCompletionProbe()
        let task = Task {
            await EngramServiceRunner.runPeriodicPostIndexMaintenance {
                await started.signal()
                await release.wait()
                return 1
            } onSuccess: { (_: Int?) in
                await completion.recordEvent()
            }
        }

        await started.wait()
        task.cancel()
        await release.signal()

        let completed = await task.value
        let eventCount = await completion.eventCount()
        XCTAssertFalse(completed)
        XCTAssertEqual(eventCount, 0)
    }

    func testRunnerPeriodicScanSplitsWriteGateAcrossPhases() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let start = try XCTUnwrap(source.range(of: #"gate.performWriteCommand(name: "indexRecent")"#))
        let end = try XCTUnwrap(source.range(of: "RepoDiscovery.probeRepositories", options: [], range: start.lowerBound..<source.endIndex))
        let periodicBeforeGitProbe = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(source.contains(#"performWriteCommand(name: "periodicParentBackfills")"#))
        XCTAssertTrue(source.contains(#"commandName: "periodicFtsDrain""#))
        XCTAssertTrue(source.contains("performWriteCommand(name: commandName)"))
        // Wave 7C M01: pure status reads use performReadCommand (no gen bump).
        XCTAssertTrue(
            source.contains(#"performReadCommand(name: "periodicIndexStatus")"#)
                || source.contains(#"performWriteCommand(name: "periodicIndexStatus")"#)
        )
        XCTAssertTrue(source.contains(#"performReadCommand(name: "\(phaseName)Candidates")"#))
        XCTAssertTrue(periodicBeforeGitProbe.contains("drainRecoverableFtsJobs("))
        XCTAssertTrue(source.contains("runRecoverableJobsOnce()"))
        XCTAssertFalse(
            periodicBeforeGitProbe.contains("runRecoverableJobs()"),
            "periodic FTS drain must release the write gate between batches"
        )

        let indexRecentEnd = try XCTUnwrap(
            source.range(of: #"performWriteCommand(name: "periodicParentBackfills")"#, options: [], range: start.lowerBound..<source.endIndex)
        )
        let indexRecentBlock = String(source[start.lowerBound..<indexRecentEnd.lowerBound])
        XCTAssertFalse(indexRecentBlock.contains("runPeriodicParentBackfills()"))
        XCTAssertFalse(indexRecentBlock.contains("runRecoverableJobs"))
        XCTAssertFalse(indexRecentBlock.contains("RepoDiscovery.sessionCwdCounts"))
    }

    func testRunnerPeriodicScanRefreshesCountsAfterParentBackfills() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let start = try XCTUnwrap(source.range(of: #"performWriteCommand(name: "periodicParentBackfills")"#))
        let end = try XCTUnwrap(source.range(of: "RepoDiscovery.probeRepositories", options: [], range: start.lowerBound..<source.endIndex))
        let loop = String(source[start.lowerBound..<end.lowerBound])

        let backfills = try XCTUnwrap(loop.range(of: "runPeriodicParentBackfills()"))
        let status = try XCTUnwrap(
            loop.range(of: #"performReadCommand(name: "periodicIndexStatus")"#)
                ?? loop.range(of: #"performWriteCommand(name: "periodicIndexStatus")"#)
        )
        XCTAssertLessThan(backfills.lowerBound, status.lowerBound)
        XCTAssertTrue(source.contains("total=\\(total) todayParents=\\(todayParents)"))
        XCTAssertTrue(source.contains("summary?.total ?? scan.total"))
        XCTAssertTrue(source.contains("summary?.todayParents ?? scan.todayParents"))
        XCTAssertTrue(source.contains("total: status.total"))
        XCTAssertTrue(source.contains("todayParents: status.todayParents"))
    }

    func testIndexingLoopSchedulesDeferredFtsBacklogBeforeAdaptiveScan_repro() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        XCTAssertTrue(source.contains("nextFtsRetryDelaySeconds"))
        XCTAssertTrue(source.contains("runFtsOnlyCycle"))
        XCTAssertTrue(source.contains("min(adaptiveSleepSeconds, max(ftsRetryDelaySeconds, 1))"))
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
        XCTAssertTrue(testSource.contains("let missingSrc ="))
        XCTAssertTrue(testSource.contains("let missingDst ="))
        XCTAssertTrue(testSource.contains("defer { try? FileManager.default.removeItem(at: missingSrc) }"))
        XCTAssertTrue(testSource.contains("defer { try? FileManager.default.removeItem(at: missingDst) }"))
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

    func testUnixSocketServiceServerOffloadsAcceptAndWakesItOnStop() throws {
        // N42: accept() is a POSIX blocking call too. It must not occupy a Swift
        // cooperative-executor thread, and stop() must actively wake a blocked
        // accept before closing the listener.
        let source = try serviceCoreSource("EngramService/IPC/UnixSocketServiceServer.swift")

        XCTAssertTrue(
            source.contains("acceptClientOffCooperativePool"),
            "listener accept must hop to the dedicated blocking I/O queue"
        )
        guard let loopStart = source.range(of: "let acceptTask = Task.detached") else {
            return XCTFail("missing accept task")
        }
        let acceptLoopPrefix = String(source[loopStart.lowerBound...].prefix(1_200))
        XCTAssertTrue(acceptLoopPrefix.contains("try await Self.acceptClientOffCooperativePool"))
        XCTAssertFalse(
            acceptLoopPrefix.contains("accept(descriptor"),
            "accept loop must not call blocking accept() directly on the cooperative pool"
        )
        XCTAssertTrue(
            source.contains("shutdown(snapshot.descriptor, SHUT_RDWR)"),
            "stop() must wake a blocked accept before closing the listener"
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

    func testUnixSocketServiceServerDrainsCancelledClientHandlersBeforeReturning_repro() async throws {
        let paths = try makeServiceIPCPaths()
        let requestStarted = CheckpointTestSignal()
        let handlerRelease = CheckpointTestSignal()
        let handlerFinished = CheckpointTestSignal()
        let drainReturned = CheckpointTestSignal()
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await requestStarted.signal()
            await handlerRelease.wait()
            await handlerFinished.signal()
            return .success(requestId: request.requestId, result: Data("{}".utf8))
        }
        try server.start()

        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        )
        let requestTask = Task { _ = try? await client.status() }
        await requestStarted.wait()

        server.stop()
        let drainTask = Task {
            let drained = await server.drainClientHandlers(timeoutNanoseconds: 1_000_000_000)
            await drainReturned.signal()
            return drained
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let drainReturnedEarly = await drainReturned.isSignaled()
        XCTAssertFalse(
            drainReturnedEarly,
            "drain must not report completion while a cancelled handler is still unwinding"
        )

        await handlerRelease.signal()
        let drainSucceeded = await drainTask.value
        let handlerDidFinish = await handlerFinished.isSignaled()
        XCTAssertTrue(drainSucceeded)
        XCTAssertTrue(handlerDidFinish)
        XCTAssertEqual(server.activeClientTaskCountForTesting(), 0)
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
        try await waitUntilServerDrainsClientTasks(server)
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
        XCTAssertEqual(status, .starting)
    }

    func testStatusMonitorReportsStartingUntilFirstSuccessfulScan() async {
        let monitor = ServiceStatusMonitor(staleAfter: 600)

        let status = await monitor.status(indexStatus: EngramDatabaseIndexStatus(total: 42, todayParents: 7))

        XCTAssertEqual(status, .starting)
    }

    /// R2.P2.premature_today_parents_status — socket-ready running status must not
    /// leak pre-backfill todayParents into the menu-bar badge.
    func testStatusMonitorZerosTodayParentsBeforeFirstSuccessfulScan_repro() async {
        let monitor = ServiceStatusMonitor(staleAfter: 600)
        await monitor.recordServiceReady()
        await monitor.recordSchedule(nextScanIntervalSeconds: 300)

        let status = await monitor.status(
            indexStatus: EngramDatabaseIndexStatus(total: 42, todayParents: 7)
        )

        XCTAssertEqual(
            status,
            .running(total: 42, todayParents: 0, nextScanIntervalSeconds: 300)
        )
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

    func testStatusMonitorUsesPublishedScheduleBeforeDeclaringScanStale() async {
        let monitor = ServiceStatusMonitor(
            staleAfter: 600,
            now: { Date(timeIntervalSince1970: 1_200) }
        )
        await monitor.recordSchedule(nextScanIntervalSeconds: 900)
        await monitor.recordScanSuccess(at: Date(timeIntervalSince1970: 100))

        let status = await monitor.status(
            indexStatus: EngramDatabaseIndexStatus(total: 42, todayParents: 7)
        )

        XCTAssertEqual(
            status,
            .running(
                total: 42,
                todayParents: 7,
                nextScanIntervalSeconds: 900,
                lastScanAt: "1970-01-01T00:01:40Z"
            )
        )
    }

    /// L-c: status must publish lastScanAt so the app can reload browse pages
    /// after a content-only scan (session count unchanged).
    func testStatusMonitorPublishesLastScanAtAfterSuccess_repro() async {
        let monitor = ServiceStatusMonitor(
            staleAfter: 600,
            now: { Date(timeIntervalSince1970: 200) }
        )
        await monitor.recordScanSuccess(at: Date(timeIntervalSince1970: 100))
        await monitor.recordSchedule(nextScanIntervalSeconds: 900)

        let status = await monitor.status(
            indexStatus: EngramDatabaseIndexStatus(total: 42, todayParents: 7)
        )

        guard case .running(let total, let todayParents, let interval, let lastScanAt) = status else {
            return XCTFail("expected running status, got \(status)")
        }
        XCTAssertEqual(total, 42)
        XCTAssertEqual(todayParents, 7)
        XCTAssertEqual(interval, 900)
        XCTAssertEqual(lastScanAt, "1970-01-01T00:01:40Z")
    }

    func testStatusMonitorStillDegradesAfterTwoPublishedIntervals() async {
        let monitor = ServiceStatusMonitor(
            staleAfter: 600,
            now: { Date(timeIntervalSince1970: 1_901) }
        )
        await monitor.recordSchedule(nextScanIntervalSeconds: 900)
        await monitor.recordScanSuccess(at: Date(timeIntervalSince1970: 100))

        let status = await monitor.status(
            indexStatus: EngramDatabaseIndexStatus(total: 42, todayParents: 7)
        )

        XCTAssertEqual(
            status,
            .degraded(message: "Last successful index scan is stale (1801s old)")
        )
    }

    func testStatusMonitorDeferredOpportunityRefreshesHealthyScanAge_repro() async {
        let monitor = ServiceStatusMonitor(
            staleAfter: 600,
            now: { Date(timeIntervalSince1970: 1_200) }
        )
        await monitor.recordSchedule(nextScanIntervalSeconds: 900)
        await monitor.recordScanSuccess(at: Date(timeIntervalSince1970: 100))

        await monitor.recordScanDeferred(at: Date(timeIntervalSince1970: 1_000))

        let status = await monitor.status(
            indexStatus: EngramDatabaseIndexStatus(total: 42, todayParents: 7)
        )
        XCTAssertEqual(
            status,
            .running(
                total: 42,
                todayParents: 7,
                nextScanIntervalSeconds: 900,
                lastScanAt: "1970-01-01T00:16:40Z"
            )
        )
    }

    func testRunnerRecordsSchedulerAndLowPowerDeferralsAsHealthy_repro() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        XCTAssertTrue(
            source.contains("if opportunity == .deferred {")
                && source.contains("commandName: \"deferredActivityFtsDrain\"")
        )
        let deferStart = try XCTUnwrap(
            source.range(of: "if IndexingSchedulePolicy.shouldDefer(conditions: conditions) {")
        )
        let recorded = try XCTUnwrap(
            source.range(
                of: "await statusMonitor.recordScanDeferred()",
                range: deferStart.upperBound..<source.endIndex
            )
        )
        let returned = try XCTUnwrap(
            source.range(of: "return", range: recorded.upperBound..<source.endIndex)
        )
        XCTAssertLessThan(recorded.lowerBound, returned.lowerBound)
    }

    func testRunnerRefreshesUsageBeforeBothDeferredCycleReturns_repro() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let schedulerStart = try XCTUnwrap(source.range(of: "if opportunity == .deferred {"))
        let schedulerEnd = try XCTUnwrap(
            source.range(
                of: "// .deferred / .run both continue",
                range: schedulerStart.upperBound..<source.endIndex
            )
        )
        let schedulerBody = source[schedulerStart.lowerBound..<schedulerEnd.lowerBound]
        XCTAssertTrue(schedulerBody.contains("collectUsageBestEffort("))

        let lowPowerStart = try XCTUnwrap(
            source.range(of: "if IndexingSchedulePolicy.shouldDefer(conditions: conditions) {")
        )
        let lowPowerEnd = try XCTUnwrap(
            source.range(
                of: "let recentAdapters = await recentAdaptersForPeriodicCycle(",
                range: lowPowerStart.upperBound..<source.endIndex
            )
        )
        let lowPowerBody = source[lowPowerStart.lowerBound..<lowPowerEnd.lowerBound]
        XCTAssertTrue(lowPowerBody.contains("collectUsageBestEffort("))
    }

    func testRunnerRefreshesUsageAndRepoCountsAfterFtsOnlyAndDeferredCycles_repro() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let ftsStart = try XCTUnwrap(source.range(of: "if ftsOnlyDue {"))
        let ftsEnd = try XCTUnwrap(
            source.range(of: "let tolerance =", range: ftsStart.upperBound..<source.endIndex)
        )
        let ftsBody = source[ftsStart.lowerBound..<ftsEnd.lowerBound]
        XCTAssertTrue(ftsBody.contains("runFtsOnlyCycle"))
        XCTAssertTrue(ftsBody.contains("collectUsageBestEffort("))
        XCTAssertTrue(ftsBody.contains("refreshRepoDiscovery("))

        let schedulerStart = try XCTUnwrap(source.range(of: "if opportunity == .deferred {"))
        let schedulerEnd = try XCTUnwrap(
            source.range(of: "// .deferred / .run both continue", range: schedulerStart.upperBound..<source.endIndex)
        )
        XCTAssertTrue(source[schedulerStart.lowerBound..<schedulerEnd.lowerBound].contains("refreshRepoDiscovery("))

        let lowPowerStart = try XCTUnwrap(
            source.range(of: "if IndexingSchedulePolicy.shouldDefer(conditions: conditions) {")
        )
        let lowPowerEnd = try XCTUnwrap(
            source.range(
                of: "let recentAdapters = await recentAdaptersForPeriodicCycle(",
                range: lowPowerStart.upperBound..<source.endIndex
            )
        )
        XCTAssertTrue(source[lowPowerStart.lowerBound..<lowPowerEnd.lowerBound].contains("refreshRepoDiscovery("))
    }

    func testFtsOnlyCyclePublishesHealthyNonzeroNextSchedule_repro() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let dueStart = try XCTUnwrap(source.range(of: "if ftsOnlyDue {"))
        let dueEnd = try XCTUnwrap(
            source.range(of: "let tolerance =", range: dueStart.upperBound..<source.endIndex)
        )
        let dueBody = source[dueStart.lowerBound..<dueEnd.lowerBound]
        XCTAssertTrue(dueBody.contains("statusMonitor: statusMonitor"))
        XCTAssertTrue(source.contains("ftsOnlyDue ? IndexingSchedulePolicy.minInterval"))

        let cycleStart = try XCTUnwrap(source.range(of: "private static func runFtsOnlyCycle("))
        let cycleEnd = try XCTUnwrap(
            source.range(of: "/// One adaptive scan cycle", range: cycleStart.upperBound..<source.endIndex)
        )
        let cycleBody = source[cycleStart.lowerBound..<cycleEnd.lowerBound]
        XCTAssertTrue(cycleBody.contains("recordScanDeferred()"))
        XCTAssertTrue(source.contains("max(ftsRetryDelaySeconds, 1)"))
    }

    func testFtsOnlyCycleDoesNotPostponeAlreadyScheduledFileScan_repro() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let dueStart = try XCTUnwrap(source.range(of: "if ftsOnlyDue {"))
        let dueEnd = try XCTUnwrap(
            source.range(of: "let tolerance =", range: dueStart.upperBound..<source.endIndex)
        )
        let dueBody = source[dueStart.lowerBound..<dueEnd.lowerBound]
        XCTAssertFalse(dueBody.contains("\n                continue\n"))
        XCTAssertTrue(source.contains("fileScanSleepSeconds"))
    }

    func testFtsOnlyCycleSleepsUntilPublishedRetryAndHeartbeatsEachBatch_repro() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let dueStart = try XCTUnwrap(source.range(of: "if ftsOnlyDue {"))
        let dueEnd = try XCTUnwrap(
            source.range(of: "let tolerance =", range: dueStart.upperBound..<source.endIndex)
        )
        let dueBody = source[dueStart.lowerBound..<dueEnd.lowerBound]
        XCTAssertTrue(dueBody.contains("sleepBeforeFtsOnlyCycle(seconds: sleepSeconds)"))

        let drainStart = try XCTUnwrap(source.range(of: "private static func drainRecoverableFtsJobs("))
        let drainEnd = try XCTUnwrap(
            source.range(of: "/// Refresh repository counts", range: drainStart.upperBound..<source.endIndex)
        )
        let drainBody = source[drainStart.lowerBound..<drainEnd.lowerBound]
        XCTAssertTrue(drainBody.contains("await onProgress()"))
        XCTAssertTrue(drainBody.contains("enqueueStaleFtsJobs()"))
        XCTAssertTrue(drainBody.contains("ftsDrainHeartbeat"))
    }

    func testForcedSchedulerDeferralStillDrainsRecoverableFts_repro() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "seedDeferredFtsDrain") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (
                      id, source, start_time, file_path, tier, offload_state, summary
                    ) VALUES (
                      'deferred-fts', 'claude-code', '2026-08-23T00:00:00Z',
                      '/tmp/deferred-fts.jsonl', 'normal', 'offloaded', 'deferred searchable shadow'
                    );
                    INSERT INTO session_index_jobs (
                      id, session_id, job_kind, target_sync_version, status
                    ) VALUES (
                      'deferred-fts:1:fts', 'deferred-fts', 'fts', 1, 'pending'
                    );
                    """)
            }
        }
        let scheduler = RecordingIndexingBackgroundActivityScheduler()
        scheduler.forceDeferred = true
        let loop = Task {
            await EngramServiceRunner.runIndexingLoop(
                gate: gate,
                statusMonitor: ServiceStatusMonitor(),
                environment: [:],
                tokenLimitsProvider: { [:] },
                activityScheduler: scheduler
            )
        }

        var indexed = false
        for _ in 0..<100 {
            indexed = try await gate.performReadCommand(name: "observeDeferredFtsDrain") { writer in
                try writer.read { db in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'deferred-fts'"
                    ) ?? 0
                }
            }.value > 0
            if indexed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        loop.cancel()
        await loop.value

        XCTAssertTrue(indexed, "an OS-deferred periodic opportunity must still drain durable FTS work")
        XCTAssertEqual(scheduler.workInvocations, 0, "forceDeferred proves the normal activity body never ran")
    }

    func testDeferredCycleEnqueuesMissingFtsRowsBeforeDrain_repro() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "seedMissingFtsJob") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (
                      id, source, start_time, file_path, source_locator,
                      snapshot_hash, sync_version, tier, offload_state, summary
                    ) VALUES (
                      'missing-fts-job', 'claude-code', '2026-08-24T00:00:00Z',
                      '/tmp/missing-fts-job.jsonl', '/tmp/missing-fts-job.jsonl',
                      'hash-v1', 1, 'normal', 'offloaded', 'stale hole searchable'
                    );
                    """)
            }
        }
        let scheduler = RecordingIndexingBackgroundActivityScheduler()
        scheduler.forceDeferred = true
        let loop = Task {
            await EngramServiceRunner.runIndexingLoop(
                gate: gate,
                statusMonitor: ServiceStatusMonitor(),
                environment: [:],
                tokenLimitsProvider: { [:] },
                activityScheduler: scheduler
            )
        }

        var indexed = false
        for _ in 0..<100 {
            indexed = try await gate.performReadCommand(name: "observeMissingFtsJob") { writer in
                try writer.read { db in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'missing-fts-job'"
                    ) ?? 0
                }
            }.value > 0
            if indexed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        loop.cancel()
        await loop.value

        XCTAssertTrue(indexed, "periodic recovery must enqueue live FTS holes, not only startup")
    }

    func testDueFtsDrainBypassesDiscretionaryScheduler_repro() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "seedImmediateFtsDrain") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (
                      id, source, start_time, file_path, tier, offload_state, summary
                    ) VALUES (
                      'immediate-fts', 'claude-code', '2026-08-23T00:00:00Z',
                      '/tmp/immediate-fts.jsonl', 'normal', 'offloaded', 'immediate searchable shadow'
                    );
                    INSERT INTO session_index_jobs (
                      id, session_id, job_kind, target_sync_version, status
                    ) VALUES ('immediate-fts:1:fts', 'immediate-fts', 'fts', 1, 'pending');
                    """)
            }
        }
        let scheduler = RecordingIndexingBackgroundActivityScheduler()
        scheduler.forceDeferred = true
        let loop = Task {
            await EngramServiceRunner.runIndexingLoop(
                gate: gate,
                statusMonitor: ServiceStatusMonitor(),
                environment: [:],
                tokenLimitsProvider: { [:] },
                activityScheduler: scheduler
            )
        }

        var indexed = false
        for _ in 0..<100 {
            indexed = try await gate.performReadCommand(name: "observeImmediateFtsDrain") { writer in
                try writer.read { db in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'immediate-fts'"
                    ) ?? 0
                }
            }.value > 0
            if indexed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        loop.cancel()
        await loop.value

        XCTAssertTrue(indexed)
        XCTAssertEqual(scheduler.workInvocations, 0)
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let directStart = try XCTUnwrap(source.range(of: "if ftsOnlyDue {"))
        let schedulerStart = try XCTUnwrap(
            source.range(of: "activityScheduler.performWhenDue(", range: directStart.upperBound..<source.endIndex)
        )
        let directBody = source[directStart.lowerBound..<schedulerStart.lowerBound]
        XCTAssertTrue(directBody.contains("runFtsOnlyCycle"))
        XCTAssertTrue(directBody.contains("fileScanSleepSeconds = max(fileScanDueAt.timeIntervalSinceNow, 0)"))
    }

    func testRunnerCancellationReleasesWriterGateAndRemovesSocket() async throws {
        let paths = try makeServiceIPCPaths()
        let home = paths.runtime.deletingLastPathComponent()
            .appendingPathComponent("home", isDirectory: true)
        let settingsDirectory = home.appendingPathComponent(".engram", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        try #"{"remoteOffloadEnabled":false,"titleProvider":"native"}"#.write(
            to: settingsURL,
            atomically: true,
            encoding: .utf8
        )
        let homeScope = ServiceCoreTestHomeScope(home: home)
        defer { homeScope.restore() }

        let runner = Task {
            try await EngramServiceRunner.run(
                arguments: [
                    "--service-socket", paths.socket.path,
                    "--database-path", paths.database.path
                ],
                environment: [
                    "ENGRAM_REMOTE_OFFLOAD_ENABLED": "false",
                    "ENGRAM_SETTINGS_PATH": settingsURL.path,
                ]
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

    func testCustomSocketParentNeverBecomesTheServiceRuntimeDirectory_repro() async throws {
        let paths = try makeServiceIPCPaths()
        let home = paths.runtime.deletingLastPathComponent()
            .appendingPathComponent("custom-runtime-home", isDirectory: true)
        let customParent = paths.runtime.deletingLastPathComponent()
            .appendingPathComponent("caller-owned-socket-parent", isDirectory: true)
        try FileManager.default.createDirectory(
            at: customParent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let socket = customParent.appendingPathComponent("custom.sock")
        let sentinel = customParent.appendingPathComponent("webui.token")
        try "caller-owned".write(to: sentinel, atomically: true, encoding: .utf8)
        let settingsDirectory = home.appendingPathComponent(".engram", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        try #"{"remoteOffloadEnabled":false,"titleProvider":"native"}"#.write(
            to: settingsURL,
            atomically: true,
            encoding: .utf8
        )
        let homeScope = ServiceCoreTestHomeScope(home: home)
        defer { homeScope.restore() }

        let runner = Task {
            try await EngramServiceRunner.run(
                arguments: ["--service-socket", socket.path, "--database-path", paths.database.path],
                environment: [
                    "ENGRAM_REMOTE_OFFLOAD_ENABLED": "false",
                    "ENGRAM_SETTINGS_PATH": settingsURL.path,
                ]
            )
        }
        try await waitUntilFileExists(socket.path)

        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "caller-owned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: customParent.appendingPathComponent("engram-service.lock").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: customParent.appendingPathComponent("cmd.token").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path + ".cmd.token"))

        runner.cancel()
        _ = try? await runner.value
    }

    func testCustomSocketRunnerDoesNotInitializeDedicatedHomeRuntime_repro() async throws {
        let paths = try makeServiceIPCPaths()
        let injectedHome = paths.runtime.deletingLastPathComponent()
            .appendingPathComponent("explicit-runner-home", isDirectory: true)
        let settingsDirectory = injectedHome.appendingPathComponent(".engram", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        try #"{"remoteOffloadEnabled":false,"titleProvider":"native"}"#.write(
            to: settingsURL,
            atomically: true,
            encoding: .utf8
        )
        let dedicatedRuntime = settingsDirectory.appendingPathComponent("run", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dedicatedRuntime.path))

        let blockingGate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime
        )
        _ = blockingGate
        do {
            try await EngramServiceRunner.run(
                arguments: [
                    "--service-socket", paths.socket.path,
                    "--database-path", paths.database.path,
                ],
                environment: [
                    "XCTestConfigurationFilePath": "/tmp/engram-tests.xctestconfiguration",
                    "CFFIXED_USER_HOME": injectedHome.path,
                    "HOME": injectedHome.path,
                    "ENGRAM_REMOTE_OFFLOAD_ENABLED": "false",
                    "ENGRAM_SETTINGS_PATH": settingsURL.path,
                ]
            )
            XCTFail("the pre-held database lock must stop the runner after path setup")
        } catch {
            // Expected: the database lock keeps this repro before long-lived tasks.
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dedicatedRuntime.path),
            "a custom socket must not initialize the dedicated default runtime"
        )
        let runnerSource = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        XCTAssertFalse(
            runnerSource.contains("let runtimeDirectory = try UnixSocketEngramServiceTransport.secureRuntimeDirectory()"),
            "runner must not fall through to the process user's home"
        )
    }

    // Audit L18: shutdown must await a cancellation-insensitive periodic WAL
    // checkpoint before starting the final TRUNCATE checkpoint.
    func testRunnerAwaitsCancelledCheckpointTaskBeforeShutdownContinues_repro() async {
        let checkpointEntered = CheckpointTestSignal()
        let cancellationObserved = CheckpointTestSignal()
        let checkpointRelease = CheckpointTestSignal()
        let shutdownFinished = CheckpointTestSignal()
        let checkpointTask = Task<Void, Never> {
            await withTaskCancellationHandler {
                await checkpointEntered.signal()
                await checkpointRelease.wait()
            } onCancel: {
                Task { await cancellationObserved.signal() }
            }
        }
        await checkpointEntered.wait()

        let shutdownTask = Task {
            await EngramServiceRunner.cancelAndAwaitCheckpointTask(checkpointTask)
            await shutdownFinished.signal()
        }
        await cancellationObserved.wait()

        let finishedBeforeCheckpointReturned = await shutdownFinished.isSignaled()
        XCTAssertFalse(
            finishedBeforeCheckpointReturned,
            "shutdown must not continue while the cancelled checkpoint is still in flight"
        )

        await checkpointRelease.signal()
        await shutdownTask.value

        let finishedAfterCheckpointReturned = await shutdownFinished.isSignaled()
        XCTAssertTrue(finishedAfterCheckpointReturned)
    }

    func testCancelledRunnerUsesNonblockingShutdownTruncateWhenIdle_repro() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("EngramService/Core/EngramServiceRunner.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("await waitForShutdownWriterIdle(gate: gate)"))
        XCTAssertTrue(source.contains("checkpointTruncate(waitForReaders: false)"))
        XCTAssertFalse(source.contains("let cancelledShutdown = Task.isCancelled"))
    }

    func testCancelledShutdownWaitsForDetachedWriterBeforeCheckpoint_repro() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let writeStarted = CheckpointTestSignal()
        let writeRelease = CheckpointTestSignal()
        let checkpointRan = CheckpointTestSignal()
        let holder = Task {
            try await gate.performWriteCommand(name: "projectMove") { _ in
                await writeStarted.signal()
                await writeRelease.wait()
            }
        }
        await writeStarted.wait()
        await gate.beginShutdown()

        let shutdown = Task {
            await EngramServiceRunner.waitForShutdownWriterIdle(gate: gate)
            await checkpointRan.signal()
        }

        // docs/invariants.md #1: shutdown maintenance must never queue behind
        // a still-live service writer or let process exit race that writer.
        try await Task.sleep(nanoseconds: 50_000_000)
        let ranBeforeRelease = await checkpointRan.isSignaled()
        XCTAssertFalse(ranBeforeRelease)

        await writeRelease.signal()
        _ = try await holder.value
        await shutdown.value
        let ranAfterRelease = await checkpointRan.isSignaled()
        XCTAssertTrue(ranAfterRelease)
    }

    func testWriterGateRejectsNewWritesAfterCancellationButAllowsCheckpoint_repro() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let holderStarted = CheckpointTestSignal()
        let holderRelease = CheckpointTestSignal()
        let lateWriteCalls = LockedCounter()
        let holder = Task {
            try await gate.performWriteCommand(name: "heldBeforeShutdown") { _ in
                await holderStarted.signal()
                await holderRelease.wait()
            }
        }
        await holderStarted.wait()

        let lateWrite = Task { () -> EngramServiceError? in
            do {
                _ = try await gate.performWriteCommand(name: "indexRecent") { _ in
                    lateWriteCalls.increment()
                }
                return nil
            } catch let error as EngramServiceError {
                return error
            } catch {
                XCTFail("unexpected late-write error: \(error)")
                return nil
            }
        }
        let queueDeadline = ContinuousClock.now + .seconds(1)
        while await gate.queuedWriteWaiterCountForTesting() == 0 {
            guard ContinuousClock.now < queueDeadline else {
                XCTFail("late write did not queue behind the held gate")
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        await gate.beginShutdown()
        await holderRelease.signal()
        _ = try await holder.value

        let lateWriteError = await lateWrite.value
        XCTAssertEqual(
            lateWriteError,
            .serviceUnavailable(message: "EngramService is shutting down")
        )
        XCTAssertEqual(lateWriteCalls.value, 0)

        do {
            _ = try await gate.performWriteCommand(name: "postShutdownWrite") { _ in
                lateWriteCalls.increment()
            }
            XCTFail("shutdown must reject writes before they queue")
        } catch let error as EngramServiceError {
            XCTAssertEqual(
                error,
                .serviceUnavailable(message: "EngramService is shutting down")
            )
        }
        XCTAssertEqual(lateWriteCalls.value, 0)

        await EngramServiceRunner.waitForShutdownWriterIdle(gate: gate)
        let checkpointed = try await EngramServiceRunner.runShutdownCheckpoint {
            try await gate.checkpointWal()
            return true
        }
        XCTAssertEqual(checkpointed, true)
    }

    // An orderly, non-cancelled shutdown can still run the full TRUNCATE in a
    // fresh task after all background writers have unwound.
    func testRunnerFinalCheckpointRunsForOrderlyShutdown() async throws {
        let callerBlocked = CheckpointTestSignal()
        let callerRelease = CheckpointTestSignal()
        let checkpointRan = CheckpointTestSignal()
        let shutdownTask = Task {
            await callerBlocked.signal()
            await callerRelease.wait()
            return try await EngramServiceRunner.runShutdownCheckpoint {
                try Task.checkCancellation()
                await checkpointRan.signal()
                return (busy: 0, logFrames: 4, checkpointed: 4)
            }
        }
        await callerBlocked.wait()

        await callerRelease.signal()

        let result = try await shutdownTask.value
        XCTAssertEqual(result.busy, 0)
        XCTAssertEqual(result.logFrames, 4)
        XCTAssertEqual(result.checkpointed, 4)
        let didRunCheckpoint = await checkpointRan.isSignaled()
        XCTAssertTrue(didRunCheckpoint)
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
        let memory = try await client.memoryFiles()
        let replay = try await client.replayTimeline(sessionId: "session-1", limit: 25)

        XCTAssertEqual(health.status, "healthy")
        XCTAssertEqual(live.count, 0)
        XCTAssertEqual(sources, [])
        XCTAssertEqual(memory, [])
        XCTAssertEqual(replay.sessionId, "session-1")
    }

    func testSQLiteReadProviderServesSearchAndSources() async throws {
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
            EngramServiceSourceInfo(
                name: "codex",
                sessionCount: 2,
                latestIndexed: "2026-04-23T02:00:00Z",
                searchableSessionCount: 2,
                searchCoveragePercent: 100,
                healthStatus: "healthy"
            )
        ])
    }

    func testSQLiteReadProviderSourcesExposeArchiveHealthFacts() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE session_index_jobs (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  job_kind TEXT NOT NULL,
                  target_sync_version INTEGER NOT NULL,
                  status TEXT NOT NULL,
                  retry_count INTEGER NOT NULL DEFAULT 0,
                  last_error TEXT,
                  created_at TEXT NOT NULL DEFAULT (datetime('now')),
                  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE TABLE session_costs (
                  session_id TEXT PRIMARY KEY,
                  model TEXT,
                  input_tokens INTEGER DEFAULT 0,
                  output_tokens INTEGER DEFAULT 0,
                  cache_read_tokens INTEGER DEFAULT 0,
                  cache_creation_tokens INTEGER DEFAULT 0,
                  cost_usd REAL DEFAULT 0,
                  computed_at TEXT
                );
                CREATE TABLE usage_snapshots (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  source TEXT NOT NULL,
                  metric TEXT NOT NULL,
                  value REAL NOT NULL,
                  unit TEXT DEFAULT '%',
                  reset_at TEXT,
                  limit_value REAL,
                  status TEXT,
                  collected_at TEXT NOT NULL
                );
                INSERT INTO session_index_jobs(
                  id, session_id, job_kind, target_sync_version, status, retry_count, last_error
                ) VALUES (
                  's2:1:hash:fts', 's2', 'fts', 1, 'failed_permanent', 3, 'malformed JSON'
                );
                INSERT INTO session_costs(
                  session_id, model, input_tokens, output_tokens,
                  cache_read_tokens, cache_creation_tokens, cost_usd, computed_at
                ) VALUES (
                  's1', 'gpt-5.4', 120, 30, 0, 0, 0.12, '2026-04-23T02:10:00Z'
                );
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, model, message_count,
                  user_message_count, assistant_message_count, file_path, size_bytes, indexed_at
                ) VALUES (
                  's3', 'opencode', '2026-04-23T02:30:00Z', '/tmp/engram', 'engram',
                  'opencode-model', 2, 1, 1, '/tmp/s3.jsonl', 44, '2026-04-23T02:30:00Z'
                );
                INSERT INTO sessions_fts(session_id, content) VALUES ('s3', 'opencode text');
                INSERT INTO usage_snapshots(source, metric, value, unit, reset_at, limit_value, status, collected_at)
                VALUES
                  ('codex', '5h window used', 64.5, '%', '2026-04-23T07:00:00Z', NULL, NULL, '2026-04-23T02:00:00Z'),
                  ('codex', '5h window used', 71.0, '%', '2026-04-23T07:00:00Z', NULL, NULL, '2026-04-23T02:05:00Z'),
                  ('codex', 'weekly quota pressure', 91.0, '%', '2026-04-30T00:00:00Z', 100.0, 'critical', '2026-04-23T02:06:00Z'),
                  ('codex', '5h token share', 36.1, '%', NULL, NULL, NULL, '2026-04-23T02:05:00Z'),
                  ('opencode', '5h token share', 55.0, '%', NULL, NULL, NULL, '2026-04-23T02:05:00Z'),
                  ('opencode', '5h token pressure', 12.0, '%', '2026-04-23T07:00:00Z', 100.0, 'ok', '2026-04-23T02:05:00Z'),
                  ('opencode', '7d cost share', 91.0, '%', NULL, NULL, NULL, '2026-04-23T02:05:00Z');
                """)
        }

        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let sources = try await provider.sources()
        let codex = sources.first { $0.name == "codex" }
        XCTAssertEqual(codex?.sessionCount, 2)
        XCTAssertEqual(codex?.searchableSessionCount, 2)
        XCTAssertEqual(codex?.searchCoveragePercent, 100)
        XCTAssertEqual(codex?.failedIndexJobCount, 1)
        XCTAssertEqual(codex?.tokenSessionCount, 1)
        XCTAssertEqual(codex?.tokenCoveragePercent, 50)
        XCTAssertEqual(codex?.costedSessionCount, 1)
        XCTAssertEqual(codex?.latestUsageMetric, "weekly quota pressure")
        XCTAssertEqual(codex?.latestUsageValue, 91.0)
        XCTAssertEqual(codex?.latestUsageUnit, "%")
        XCTAssertEqual(codex?.latestUsageLimitValue, 100.0)
        XCTAssertEqual(codex?.latestUsageResetAt, "2026-04-30T00:00:00Z")
        XCTAssertEqual(codex?.latestUsageStatus, "critical")
        XCTAssertEqual(codex?.healthStatus, "critical")

        let opencode = sources.first { $0.name == "opencode" }
        XCTAssertEqual(opencode?.tokenCoveragePercent, 0)
        XCTAssertEqual(opencode?.latestUsageMetric, "5h token pressure")
        XCTAssertEqual(opencode?.latestUsageValue, 12.0)
        XCTAssertEqual(opencode?.latestUsageUnit, "%")
        XCTAssertEqual(opencode?.latestUsageLimitValue, 100.0)
        XCTAssertEqual(opencode?.latestUsageResetAt, "2026-04-23T07:00:00Z")
        XCTAssertEqual(opencode?.latestUsageStatus, "ok")
        XCTAssertEqual(opencode?.healthStatus, "healthy")
    }

    // Mirror row 2 / source-health-predicate: skip sessions must not dilute the
    // health denominator. Parent: s3 makes coverage 67% partial; branch: healthy.
    // See docs/source-health-predicate-design-2026-07.md.
    func testSourceHealthExcludesSkipTierSessions_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, model, message_count,
                  user_message_count, assistant_message_count, file_path, size_bytes,
                  indexed_at, tier
                ) VALUES (
                  's3', 'codex', '2026-04-23T03:00:00Z', '/tmp/engram', 'engram',
                  'gpt-5.4', 2, 1, 1, '/tmp/s3.jsonl', 44, '2026-04-23T03:00:00Z', 'skip'
                );
                """)
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)
        let sources = try await provider.sources()
        let codex = try XCTUnwrap(sources.first { $0.name == "codex" })
        XCTAssertEqual(codex.healthStatus, "healthy")
        XCTAssertEqual(codex.searchableSessionCount, 2)
        XCTAssertEqual(codex.searchCoveragePercent, 100)
        XCTAssertNil(codex.healthReason)
    }

    // Mirror row 2: lite is index-eligible; skip is not. s6 forces parent vs branch
    // coverage to diverge (60 vs 75). Counts also reject searchableTierSQL.
    // See docs/source-health-predicate-design-2026-07.md.
    func testSourceHealthCountsLiteTierSessions_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, model, message_count,
                  user_message_count, assistant_message_count, file_path, size_bytes,
                  indexed_at, tier
                ) VALUES
                  ('s4', 'codex', '2026-04-23T04:00:00Z', '/tmp/engram', 'engram',
                   'gpt-5.4', 2, 1, 1, '/tmp/s4.jsonl', 44, '2026-04-23T04:00:00Z', 'lite'),
                  ('s5', 'codex', '2026-04-23T05:00:00Z', '/tmp/engram', 'engram',
                   'gpt-5.4', 2, 1, 1, '/tmp/s5.jsonl', 44, '2026-04-23T05:00:00Z', 'lite'),
                  ('s6', 'codex', '2026-04-23T06:00:00Z', '/tmp/engram', 'engram',
                   'gpt-5.4', 2, 1, 1, '/tmp/s6.jsonl', 44, '2026-04-23T06:00:00Z', 'skip');
                INSERT INTO sessions_fts(session_id, content) VALUES ('s4', 'lite with fts');
                """)
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)
        let sources = try await provider.sources()
        let codex = try XCTUnwrap(sources.first { $0.name == "codex" })
        XCTAssertEqual(codex.searchableSessionCount, 3)
        XCTAssertEqual(codex.searchCoveragePercent, 75)
        XCTAssertEqual(codex.healthStatus, "partial")
        let reason = try XCTUnwrap(codex.healthReason)
        XCTAssertTrue(reason.contains("1 of 4"), reason)
    }

    func testSourceHealthExcludesSkipTierSessionsFromNumerator() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, model, message_count,
                  user_message_count, assistant_message_count, file_path, size_bytes,
                  indexed_at, tier
                ) VALUES (
                  's-skip', 'codex', '2026-04-23T03:00:00Z', '/tmp/engram', 'engram',
                  'gpt-5.4', 2, 1, 1, '/tmp/skip.jsonl', 44, '2026-04-23T03:00:00Z', 'skip'
                );
                INSERT INTO sessions_fts(session_id, content) VALUES ('s-skip', 'hello from skipped noise');
                """)
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)
        let sources = try await provider.sources()
        let codex = try XCTUnwrap(sources.first { $0.name == "codex" })
        XCTAssertEqual(codex.searchableSessionCount, 2)
        XCTAssertEqual(codex.healthStatus, "healthy")
        XCTAssertNil(codex.healthReason)
    }

    func testSourceHealthReportsEmptyWhenAllSessionsAreSkipTier() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, model, message_count,
                  user_message_count, assistant_message_count, file_path, size_bytes,
                  indexed_at, tier
                ) VALUES (
                  'g1', 'glm', '2026-04-23T03:00:00Z', '/tmp/engram', 'engram',
                  'glm', 2, 1, 1, '/tmp/g1.jsonl', 44, '2026-04-23T03:00:00Z', 'skip'
                );
                """)
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)
        let sources = try await provider.sources()
        let glm = try XCTUnwrap(sources.first { $0.name == "glm" })
        XCTAssertEqual(glm.sessionCount, 1)
        XCTAssertEqual(glm.searchableSessionCount, 0)
        XCTAssertEqual(glm.searchCoveragePercent, 0)
        XCTAssertEqual(glm.healthStatus, "empty")
        let reason = try XCTUnwrap(glm.healthReason)
        XCTAssertTrue(reason.contains("subagent or noise"), reason)
    }

    /// ARCH-001B: source KPI helpers must not count work attached only to skip-tier sessions.
    func testSourceKPIsExcludeSkipTierRows_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE session_index_jobs (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  job_kind TEXT NOT NULL,
                  target_sync_version INTEGER NOT NULL,
                  status TEXT NOT NULL,
                  retry_count INTEGER NOT NULL DEFAULT 0,
                  last_error TEXT,
                  created_at TEXT NOT NULL DEFAULT (datetime('now')),
                  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE TABLE session_costs (
                  session_id TEXT PRIMARY KEY,
                  model TEXT,
                  input_tokens INTEGER DEFAULT 0,
                  output_tokens INTEGER DEFAULT 0,
                  cache_read_tokens INTEGER DEFAULT 0,
                  cache_creation_tokens INTEGER DEFAULT 0,
                  cost_usd REAL DEFAULT 0,
                  computed_at TEXT
                );
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, model, message_count,
                  user_message_count, assistant_message_count, file_path, size_bytes,
                  indexed_at, tier
                ) VALUES
                  (
                    'visible-kpi', 'glm', '2026-04-23T02:00:00Z', '/tmp/engram', 'engram',
                    'glm', 2, 1, 1, '/tmp/visible-kpi.jsonl', 44, '2026-04-23T02:00:00Z', 'normal'
                  ),
                  (
                    'skip-kpi', 'glm', '2026-04-23T03:00:00Z', '/tmp/engram', 'engram',
                    'glm', 2, 1, 1, '/tmp/skip-kpi.jsonl', 44, '2026-04-23T03:00:00Z', 'skip'
                  );
                INSERT INTO session_index_jobs(
                  id, session_id, job_kind, target_sync_version, status, retry_count, last_error
                ) VALUES (
                  'skip-kpi:1:hash:fts', 'skip-kpi', 'fts', 1, 'failed_permanent', 3, 'noise'
                );
                INSERT INTO session_costs(
                  session_id, model, input_tokens, output_tokens,
                  cache_read_tokens, cache_creation_tokens, cost_usd, computed_at
                ) VALUES
                  (
                    'visible-kpi', 'glm', 120, 30, 0, 0, 0.12, '2026-04-23T02:10:00Z'
                  ),
                  (
                    'skip-kpi', 'glm', 1200, 300, 0, 0, 1.20, '2026-04-23T03:10:00Z'
                  );
                """)
        }

        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)
        let sources = try await provider.sources()
        let glm = try XCTUnwrap(sources.first { $0.name == "glm" })

        XCTAssertEqual(glm.sessionCount, 2, "raw source inventory remains diagnostic")
        XCTAssertEqual(glm.failedIndexJobCount, 0)
        XCTAssertEqual(glm.tokenSessionCount, 1)
        XCTAssertEqual(glm.tokenCoveragePercent, 100)
        XCTAssertEqual(glm.costedSessionCount, 1)
    }

    func testSourceHealthSurvivesMissingFTSTable() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "DROP TABLE sessions_fts")
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)
        let sources = try await provider.sources()
        let codex = try XCTUnwrap(sources.first { $0.name == "codex" })
        XCTAssertEqual(codex.searchableSessionCount, 0)
        XCTAssertEqual(codex.healthStatus, "partial")
        XCTAssertNotNil(codex.healthReason)
    }

    func testSQLiteReadProviderSourcesInferCriticalUsageForLegacyRemainingPercentWithoutUnit() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE usage_snapshots (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  source TEXT NOT NULL,
                  metric TEXT NOT NULL,
                  value REAL NOT NULL,
                  unit TEXT,
                  reset_at TEXT,
                  limit_value REAL,
                  status TEXT,
                  collected_at TEXT NOT NULL
                );
                INSERT INTO usage_snapshots(source, metric, value, unit, reset_at, limit_value, status, collected_at)
                VALUES (
                  'codex', 'weekly remaining', 4.0, NULL, '2026-06-08T00:00:00Z',
                  NULL, NULL, '2026-06-07T10:00:00Z'
                );
                """)
        }

        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let codex = try await provider.sources().first { $0.name == "codex" }

        XCTAssertEqual(codex?.latestUsageMetric, "weekly remaining")
        XCTAssertNil(codex?.latestUsageUnit)
        XCTAssertEqual(codex?.latestUsageStatus, "critical")
        XCTAssertEqual(codex?.healthStatus, "critical")
    }

    func testSQLiteReadProviderSourcesPrioritizeNormalizedExplicitUsageStatus() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE usage_snapshots (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  source TEXT NOT NULL,
                  metric TEXT NOT NULL,
                  value REAL NOT NULL,
                  unit TEXT,
                  reset_at TEXT,
                  limit_value REAL,
                  status TEXT,
                  collected_at TEXT NOT NULL
                );
                INSERT INTO usage_snapshots(source, metric, value, unit, reset_at, limit_value, status, collected_at)
                VALUES
                  (
                    'codex', '7d cost share', 8.0, '%', NULL,
                    NULL, ' Critical ', '2026-06-07T10:00:00Z'
                  ),
                  (
                    'codex', '5h token pressure', 72.0, '%', '2026-06-07T15:00:00Z',
                    100.0, 'attention', '2026-06-07T10:00:00Z'
                  );
                """)
        }

        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let codex = try await provider.sources().first { $0.name == "codex" }

        XCTAssertEqual(codex?.latestUsageMetric, "7d cost share")
        XCTAssertEqual(codex?.latestUsageStatus, "critical")
        XCTAssertEqual(codex?.healthStatus, "critical")
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

    func testShortSemanticQueriesDoNotClaimProviderUnavailable_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let semantic = try await provider.search(
            EngramServiceSearchRequest(query: "A", mode: "semantic", limit: 10)
        )
        XCTAssertEqual(semantic.items, [])
        XCTAssertEqual(semantic.searchModes, ["semantic"])
        XCTAssertNil(semantic.warning)
        XCTAssertNil(semantic.warningCode)

        let hybrid = try await provider.search(
            EngramServiceSearchRequest(query: "A", mode: "hybrid", limit: 10)
        )
        XCTAssertEqual(hybrid.items, [])
        XCTAssertEqual(hybrid.searchModes, ["keyword", "semantic"])
        XCTAssertNil(hybrid.warning)
        XCTAssertNil(hybrid.warningCode)
    }

    func testSearchSemanticModeUsesSemanticChunksWhenProviderConfigured() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE semantic_chunks (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  chunk_index INTEGER NOT NULL,
                  text TEXT NOT NULL,
                  embedding BLOB,
                  model TEXT,
                  dim INTEGER,
                  created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE TABLE embedding_meta (
                  id INTEGER PRIMARY KEY CHECK (id = 1),
                  provider TEXT,
                  model TEXT,
                  dimension INTEGER,
                  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                INSERT INTO embedding_meta (id, provider, model, dimension)
                VALUES (1, 'test', 'probe', 3);
                """)
            try db.execute(
                sql: """
                INSERT INTO semantic_chunks(id, session_id, chunk_index, text, embedding, model, dim)
                VALUES ('s2:c0', 's2', 0, 'semantic recall chunk', ?, 'probe', 3)
                """,
                arguments: [VectorMath.encode(VectorMath.l2Normalize([1, 0, 0]))]
            )
        }
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
            ],
            embeddingProviderFactory: { _ in
                StaticEmbeddingProvider { _ in [1, 0, 0] }
            }
        )

        let semantic = try await provider.search(
            EngramServiceSearchRequest(query: "memory recall", mode: "semantic", limit: 10)
        )

        XCTAssertEqual(semantic.items.map(\.id), ["s2"])
        XCTAssertEqual(semantic.searchModes, ["semantic"])
        XCTAssertNil(semantic.warning)
        XCTAssertEqual(semantic.items.first?.matchType, "semantic")
        XCTAssertEqual(semantic.items.first?.snippet, "semantic recall chunk")
    }

    func testSemanticSearchAppliesRequestedHQOriginBeforeCandidateAndResultLimits_repro() async throws {
        let paths = try makeServiceIPCPaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let requestLimit = 1
        try seedOriginFilteredSemanticSearchFixture(
            at: paths.database.path,
            targetOrigin: "hq",
            interferenceOrigin: "m1",
            interferenceCount: SessionSemanticSearchPolicy.candidateBatchSize(requestLimit: requestLimit) + 1
        )
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
            ],
            embeddingProviderFactory: { _ in
                StaticEmbeddingProvider { _ in [1, 0, 0] }
            }
        )

        let semantic = try await provider.search(
            EngramServiceSearchRequest(
                query: "originneedle",
                mode: "semantic",
                limit: requestLimit,
                origin: "hq"
            )
        )

        XCTAssertEqual(semantic.items.map(\.id), ["s2"])
        XCTAssertEqual(semantic.items.first?.origin, "hq")
        XCTAssertEqual(semantic.searchModes, ["semantic"])
    }

    func testHybridSearchAppliesRequestedLocalOriginBeforeCandidateAndResultLimits_repro() async throws {
        let paths = try makeServiceIPCPaths()
        defer { try? FileManager.default.removeItem(at: paths.runtime.deletingLastPathComponent()) }
        let requestLimit = 1
        try seedOriginFilteredSemanticSearchFixture(
            at: paths.database.path,
            targetOrigin: "m1",
            interferenceOrigin: "hq",
            interferenceCount: SessionSemanticSearchPolicy.candidateBatchSize(requestLimit: requestLimit) + 1
        )
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
            ],
            embeddingProviderFactory: { _ in
                StaticEmbeddingProvider { _ in [1, 0, 0] }
            }
        )

        let hybrid = try await provider.search(
            EngramServiceSearchRequest(
                query: "originneedle",
                mode: "hybrid",
                limit: requestLimit,
                origin: "local"
            )
        )

        XCTAssertEqual(hybrid.items.map(\.id), ["s2"])
        XCTAssertEqual(hybrid.items.first?.origin, "m1")
        XCTAssertEqual(hybrid.items.first?.matchType, "semantic")
        XCTAssertEqual(hybrid.searchModes, ["keyword", "semantic"])
    }

    func testSemanticAvailabilityBusyFailsClosedWithoutProviderOrKeywordRetry_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let reader = try BusySequenceServiceDatabaseReader(
            path: paths.database.path,
            busyImmediateReadNumbers: [1]
        )
        let providerCalls = LockedCounter()
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            makeDatabaseReader: { _ in reader },
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
            ],
            embeddingProviderFactory: { _ in
                providerCalls.increment()
                return StaticEmbeddingProvider { _ in [1, 0, 0] }
            }
        )

        let response = try await provider.search(
            EngramServiceSearchRequest(query: "memory recall", mode: "semantic", limit: 10)
        )

        XCTAssertEqual(response.items, [])
        XCTAssertEqual(response.searchModes, ["semantic"])
        XCTAssertEqual(response.warningCode, "searchFailed")
        XCTAssertFalse(response.warning?.localizedCaseInsensitiveContains("keyword") ?? true)
        XCTAssertEqual(reader.immediateReadCount, 1, "BUSY must not trigger a second keyword read")
        XCTAssertEqual(providerCalls.value, 0, "availability must fail before query embedding")
    }

    func testSemanticPageBusyFailsClosedWithoutKeywordRetry_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSemanticSearchFixture(at: paths.database.path)
        let reader = try BusySequenceServiceDatabaseReader(
            path: paths.database.path,
            busyImmediateReadNumbers: [2]
        )
        let providerCalls = LockedCounter()
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            makeDatabaseReader: { _ in reader },
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
            ],
            embeddingProviderFactory: { _ in
                providerCalls.increment()
                return StaticEmbeddingProvider { _ in [1, 0, 0] }
            }
        )

        let response = try await provider.search(
            EngramServiceSearchRequest(query: "memory recall", mode: "semantic", limit: 10)
        )

        XCTAssertEqual(response.items, [])
        XCTAssertEqual(response.searchModes, ["semantic"])
        XCTAssertEqual(response.warningCode, "searchFailed")
        XCTAssertFalse(response.warning?.localizedCaseInsensitiveContains("keyword") ?? true)
        XCTAssertEqual(reader.immediateReadCount, 2, "BUSY during semantic paging must not fall through to keyword")
        XCTAssertEqual(providerCalls.value, 1)
    }

    func testHybridKeywordBusyKeepsSemanticHits_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSemanticSearchFixture(at: paths.database.path)
        let reader = try BusySequenceServiceDatabaseReader(
            path: paths.database.path,
            busyReadNumbers: [1],
            busyImmediateReadNumbers: [5]
        )
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            makeDatabaseReader: { _ in reader },
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
            ],
            embeddingProviderFactory: { _ in
                StaticEmbeddingProvider { _ in [1, 0, 0] }
            }
        )

        let response = try await provider.search(
            EngramServiceSearchRequest(query: "memory recall", mode: "hybrid", limit: 10)
        )

        XCTAssertEqual(response.items.map(\.id), ["s2"])
        XCTAssertEqual(response.searchModes, ["semantic"])
        XCTAssertEqual(reader.normalReadCount, 0, "hybrid fusion must not use the 30-second reader")
        XCTAssertEqual(reader.immediateReadCount, 5)
    }

    func testSemanticHydrationBusyKeepsRankedHitsWithoutSlowRetry_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSemanticSearchFixture(at: paths.database.path)
        let reader = try BusySequenceServiceDatabaseReader(
            path: paths.database.path,
            busyReadNumbers: [1],
            busyImmediateReadNumbers: [4]
        )
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            makeDatabaseReader: { _ in reader },
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
            ],
            embeddingProviderFactory: { _ in
                StaticEmbeddingProvider { _ in [1, 0, 0] }
            }
        )

        let response = try await provider.search(
            EngramServiceSearchRequest(query: "memory recall", mode: "semantic", limit: 10)
        )

        XCTAssertEqual(response.items.map(\.id), ["s2"])
        XCTAssertEqual(response.searchModes, ["semantic"])
        XCTAssertNil(response.warningCode)
        XCTAssertEqual(reader.normalReadCount, 0, "hydration BUSY must use the in-hand visible snapshot")
    }

    func testSearchSemanticEmptyFilteredSliceIsAValidEmptyResult_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE semantic_chunks (
                  id TEXT PRIMARY KEY, session_id TEXT NOT NULL, chunk_index INTEGER NOT NULL,
                  text TEXT NOT NULL, embedding BLOB, model TEXT, dim INTEGER,
                  created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE TABLE embedding_meta (
                  id INTEGER PRIMARY KEY CHECK (id = 1), provider TEXT, model TEXT,
                  dimension INTEGER, updated_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                INSERT INTO embedding_meta (id, provider, model, dimension)
                VALUES (1, 'test', 'probe', 3);
                """)
            try db.execute(
                sql: """
                INSERT INTO semantic_chunks(id, session_id, chunk_index, text, embedding, model, dim)
                VALUES ('s2:c0', 's2', 0, 'semantic recall chunk', ?, 'probe', 3)
                """,
                arguments: [VectorMath.encode(VectorMath.l2Normalize([1, 0, 0]))]
            )
        }
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
            ],
            embeddingProviderFactory: { _ in StaticEmbeddingProvider { _ in [1, 0, 0] } }
        )

        let semantic = try await provider.search(
            EngramServiceSearchRequest(
                query: "memory recall",
                mode: "semantic",
                limit: 10,
                source: "claude-code"
            )
        )
        XCTAssertEqual(semantic.items, [])
        XCTAssertEqual(semantic.searchModes, ["semantic"])
        XCTAssertNil(semantic.warning)
        XCTAssertNil(semantic.warningCode)

        let hybrid = try await provider.search(
            EngramServiceSearchRequest(
                query: "memory recall",
                mode: "hybrid",
                limit: 10,
                source: "claude-code"
            )
        )
        XCTAssertEqual(hybrid.items, [])
        XCTAssertEqual(hybrid.searchModes, ["keyword", "semantic"])
        XCTAssertNil(hybrid.warning)
        XCTAssertNil(hybrid.warningCode)
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

    func testCancellationIsNotAdvertisedAsRetryableCommandFailure_repro() {
        let envelope = EngramServiceCommandHandler.genericErrorEnvelope(CancellationError())
        XCTAssertEqual(envelope.name, "Cancelled")
        XCTAssertEqual(envelope.retryPolicy, "never")
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

    func testSQLiteReadProviderAppliesOriginBeforeSearchLimit_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            for index in 0 ..< 31 {
                let id = "local-origin-\(index)"
                try db.execute(
                    sql: """
                        INSERT INTO sessions (
                          id, source, start_time, cwd, project, message_count,
                          file_path, size_bytes, indexed_at, tier, origin
                        ) VALUES (?, 'codex', ?, '/tmp/local', 'engram', 2,
                                  ?, 42, ?, 'normal', 'local')
                        """,
                    arguments: [
                        id,
                        String(format: "2026-08-%02dT12:00:00Z", index + 1),
                        "/tmp/\(id).jsonl",
                        String(format: "2026-08-%02dT12:30:00Z", index + 1),
                    ]
                )
                try db.execute(
                    sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, 'originneedle')",
                    arguments: [id]
                )
            }
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, message_count,
                  file_path, size_bytes, indexed_at, tier, origin
                ) VALUES (
                  'hq-origin-target', 'codex', '2000-01-01T00:00:00Z', '/tmp/hq',
                  'engram', 2, 'remote://hq/hq-origin-target', 42,
                  '2000-01-01T00:00:00Z', 'normal', 'hq'
                );
                INSERT INTO sessions_fts(session_id, content)
                VALUES ('hq-origin-target', 'originneedle');
                """)
        }
        let request = try JSONDecoder().decode(
            EngramServiceSearchRequest.self,
            from: Data(#"{"query":"originneedle","mode":"keyword","limit":30,"origin":"hq"}"#.utf8)
        )
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let search = try await provider.search(request)
        let legacyRequest = try JSONDecoder().decode(
            EngramServiceSearchRequest.self,
            from: Data(#"{"query":"originneedle","mode":"keyword","limit":30}"#.utf8)
        )
        let allMachines = try await provider.search(legacyRequest)

        XCTAssertEqual(
            search.items.map(\.id),
            ["hq-origin-target"],
            "the requested origin must constrain SQL before LIMIT"
        )
        XCTAssertNil(legacyRequest.origin)
        XCTAssertEqual(allMachines.items.count, 30, "missing origin must preserve the v1 all-machines request")
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

    func testSQLiteReadProviderKeywordSnippetSQLNeverSelectsWholeContent_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let recorder = ServiceSQLTraceRecorder()
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            makeDatabaseReader: { path in
                try TracingServiceDatabaseReader(path: path, recorder: recorder)
            }
        )

        _ = try await provider.search(
            EngramServiceSearchRequest(query: "hello", mode: "keyword", limit: 10)
        )
        _ = try await provider.search(
            EngramServiceSearchRequest(query: "你好", mode: "keyword", limit: 10)
        )

        let searchSQL = recorder.statements()
            .filter { $0.localizedCaseInsensitiveContains("FROM sessions_fts") }
            .joined(separator: "\n")
        XCTAssertFalse(
            searchSQL.localizedCaseInsensitiveContains("MIN(content)"),
            "keyword search SQL must not materialize an unbounded transcript: \(searchSQL)"
        )
        XCTAssertTrue(
            searchSQL.localizedCaseInsensitiveContains("snippet(")
                || searchSQL.localizedCaseInsensitiveContains("substr("),
            "keyword search must construct a bounded snippet in SQLite: \(searchSQL)"
        )
    }

    func testSQLiteReadProviderSearchMatchesTermsAcrossMessagesWithinSameSession() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM sessions_fts")
            try db.execute(sql: """
                INSERT INTO sessions_fts(session_id, content) VALUES ('s1', 'alpha planning note');
                INSERT INTO sessions_fts(session_id, content) VALUES ('s1', 'beta verifier note');
                INSERT INTO sessions_fts(session_id, content) VALUES ('s2', 'alpha only note');
                """)
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let search = try await provider.search(
            EngramServiceSearchRequest(query: "alpha beta", mode: "keyword", limit: 10)
        )

        XCTAssertEqual(search.items.map(\.id), ["s1"])
        let snippet = try XCTUnwrap(search.items.first?.snippet)
        XCTAssertTrue(
            snippet.contains("<mark>alpha</mark>") || snippet.contains("<mark>beta</mark>"),
            "expected a highlighted snippet from one matching message, got: \(snippet)"
        )
    }

    func testSQLiteReadProviderShortLatinSearchReturnsLiteralMatches() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions_fts SET content = ? WHERE session_id = 's1'",
                arguments: ["Ship the AI usage monitor before the release"]
            )
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let search = try await provider.search(
            EngramServiceSearchRequest(query: "AI", mode: "keyword", limit: 10)
        )

        XCTAssertEqual(search.items.map(\.id), ["s1"])
        let snippet = try XCTUnwrap(search.items.first?.snippet)
        XCTAssertTrue(
            snippet.localizedCaseInsensitiveContains("<mark>AI</mark>"),
            "expected highlighted short Latin match, got: \(snippet)"
        )
    }

    func testSQLiteReadProviderHighlightsEveryMixedTokenAcrossRows_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        try await DatabaseQueue(path: paths.database.path).write { db in
            try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = 's1'")
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('s1', 'alpha planning note')")
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('s1', 'beta verifier note')")
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let search = try await provider.search(
            EngramServiceSearchRequest(query: "alpha beta", mode: "keyword", limit: 10)
        )
        let snippet = try XCTUnwrap(search.items.first?.snippet)
        XCTAssertTrue(snippet.contains("<mark>alpha</mark>"), snippet)
        XCTAssertTrue(snippet.contains("<mark>beta</mark>"), snippet)
    }

    func testSQLiteReadProviderDeduplicatesSameFTSRowSnippet_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        try await DatabaseQueue(path: paths.database.path).write { db in
            try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = 's1'")
            try db.execute(
                sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('s1', 'alpha beta shared context')"
            )
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let search = try await provider.search(
            EngramServiceSearchRequest(query: "alpha beta", mode: "keyword", limit: 10)
        )
        let snippet = try XCTUnwrap(search.items.first?.snippet)
        XCTAssertEqual(snippet.components(separatedBy: "<mark>alpha beta</mark>").count - 1, 1, snippet)
        XCTAssertTrue(snippet.contains("<mark>alpha beta</mark>"), snippet)
    }

    func testSQLiteReadProviderMixedShortAndLongTermsUseLikeAndMatch_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions_fts SET content = ? WHERE session_id = 's1'",
                arguments: ["Ship the AI usage monitor; think, fix bug, and parser notes"]
            )
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let search = try await provider.search(
            EngramServiceSearchRequest(query: "AI usage", mode: "keyword", limit: 10)
        )

        XCTAssertEqual(search.items.map(\.id), ["s1"])

        for query in ["I think", "fix a bug", "C parser"] {
            let mixed = try await provider.search(
                EngramServiceSearchRequest(query: query, mode: "keyword", limit: 10)
            )
            XCTAssertEqual(mixed.items.map(\.id), ["s1"], "query=\(query)")
        }
    }

    func testSQLiteReadProviderRehighlightsWholeMatchFirstPhrase_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions_fts SET content = ? WHERE session_id = 's1'",
                arguments: ["Deploy the usage monitor before release"]
            )
        }
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let search = try await provider.search(
            EngramServiceSearchRequest(query: "usage monitor", mode: "keyword", limit: 10)
        )

        XCTAssertEqual(search.items.map(\.id), ["s1"])
        XCTAssertTrue(
            search.items.first?.snippet?.contains("<mark>usage monitor</mark>") ?? false,
            "got: \(search.items.first?.snippet ?? "")"
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

    // ARCH-001A: the service already treats blank search-filter strings as
    // absent; pin that behavior before replacing its local SQL assembly.
    func testSQLiteReadProviderSearchIgnoresBlankFilters_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)

        let unfiltered = try await provider.search(
            EngramServiceSearchRequest(query: "hello", mode: "keyword", limit: 10)
        )
        let blankFiltered = try await provider.search(
            EngramServiceSearchRequest(
                query: "hello",
                mode: "keyword",
                limit: 10,
                project: "\t",
                source: " \n",
                since: "  "
            )
        )

        XCTAssertEqual(blankFiltered.items.map(\.id), unfiltered.items.map(\.id))
        XCTAssertEqual(blankFiltered.items.map(\.id), ["s1"])
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
            EngramServiceSourceInfo(
                name: "codex",
                sessionCount: 2,
                latestIndexed: "2026-04-23T02:00:00Z",
                searchableSessionCount: 2,
                searchCoveragePercent: 100,
                healthStatus: "healthy"
            )
        ])

        let second = try await provider.sources()
        XCTAssertEqual(second, first)
        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(factory.reader?.readCount, 2)
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
        XCTAssertEqual(resume.args, ["resume", "s1"])
        XCTAssertEqual(resume.cwd, "/tmp/engram")
        XCTAssertEqual(resume.contextPrimer, """
        Resume context from Engram archive:
        Session: s1
        Source: codex
        CWD: /tmp/engram

        Archived context:
        - hello from swift service
        """)
        XCTAssertNil(resume.error)
    }

    func testRemoteHqSessionResumeIsHonestError_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: """
                UPDATE sessions
                SET origin = 'hq', file_path = 'remote://hq/s1', cwd = ''
                WHERE id = 's1'
                """
            )
        }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            readProvider: try SQLiteEngramServiceReadProvider(
                databasePath: paths.database.path,
                commandLocator: { command in command == "codex" ? "/usr/local/bin/codex" : nil }
            )
        )
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }
        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let resume = try await client.resumeCommand(sessionId: "s1")
        XCTAssertNil(resume.command)
        XCTAssertEqual(resume.error, "This session lives on HQ and cannot be resumed from this Mac.")
        XCTAssertTrue(resume.hint?.contains("snapshot") == true)
    }

    func testClaudeSubagentResumeDegradesToContextPrimer_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime
            .appendingPathComponent(".claude/projects/encoded/parent-claude/subagents/child-claude.jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}\n".utf8).write(to: transcript)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET source = 'claude-code', parent_session_id = ?, file_path = ? WHERE id = 's1'",
                arguments: ["parent-claude", transcript.path]
            )
        }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            readProvider: try SQLiteEngramServiceReadProvider(
                databasePath: paths.database.path,
                fileSystemProvider: FileSystemEngramServiceReadProvider(homeDirectory: paths.runtime),
                commandLocator: { command in command == "claude" ? "/usr/local/bin/claude" : nil }
            )
        )
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        let resume = try await client.resumeCommand(sessionId: "s1")

        XCTAssertNil(resume.command)
        XCTAssertEqual(resume.args, [])
        XCTAssertEqual(resume.error, "This transcript cannot be resumed directly")
        XCTAssertTrue(resume.hint?.contains("parent-claude") ?? false)
        XCTAssertFalse(resume.contextPrimer?.isEmpty ?? true)
    }

    func testClaudeManualParentOnTopLevelTranscriptRemainsResumable_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime
            .appendingPathComponent(".claude/projects/encoded/s1.jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}\n".utf8).write(to: transcript)
        try await DatabaseQueue(path: paths.database.path).write { db in
            try db.execute(
                sql: "UPDATE sessions SET source = 'claude-code', parent_session_id = 'manual-parent', link_source = 'manual', file_path = ? WHERE id = 's1'",
                arguments: [transcript.path]
            )
        }
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            fileSystemProvider: FileSystemEngramServiceReadProvider(homeDirectory: paths.runtime),
            commandLocator: { command in command == "claude" ? "/usr/local/bin/claude" : nil }
        )

        let resume = try await provider.resumeCommand(.init(sessionId: "s1"))

        XCTAssertEqual(resume.command, "/usr/local/bin/claude")
        XCTAssertEqual(resume.args, ["--resume", "s1"])
        XCTAssertNil(resume.error)
    }

    func testProductionWorkItemTitleDoesNotApplySecondPerBeatCap_repro() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EngramService/Core/EngramServiceCommandHandler.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "static func workItemTitle("))
        let end = try XCTUnwrap(source.range(of: "static func chat(", range: start.upperBound..<source.endIndex))
        let function = source[start.lowerBound..<end.lowerBound]
        XCTAssertFalse(function.contains("intent.prefix(600)"))
        XCTAssertFalse(function.contains("outcome.prefix(1200)"))
        XCTAssertTrue(function.contains(#"Intent: \(intent)"#))
        XCTAssertTrue(function.contains(#"Outcome: \(outcome)"#))
    }

    func testClaudeResumeFileIdentityUsesLeafInsteadOfAbsoluteSubagentsSubstring_repro() {
        XCTAssertTrue(
            SQLiteEngramServiceReadProvider.claudeResumeFileMatchesID(
                filePath: "/Users/test/.claude/projects/repo/session-1.jsonl",
                id: "session-1"
            )
        )
        XCTAssertTrue(
            SQLiteEngramServiceReadProvider.claudeResumeFileMatchesID(
                filePath: "/Users/test/custom/subagents/projects/repo/session-1.jsonl",
                id: "session-1"
            )
        )
        XCTAssertFalse(
            SQLiteEngramServiceReadProvider.claudeResumeFileMatchesID(
                filePath: "/Users/test/.claude/projects/repo/agent-session-1.jsonl",
                id: "session-1"
            )
        )
    }

    func testResumeCommandForEmptyCwdReturnsHintInsteadOfOpenEmptyString() {
        let resume = SQLiteEngramServiceReadProvider.openBasedResumeCommand(
            source: "cursor",
            cwd: "",
            contextPrimer: "Resume context"
        )

        XCTAssertNil(resume.command)
        XCTAssertEqual(resume.args, [])
        XCTAssertEqual(resume.cwd, "")
        XCTAssertEqual(resume.error, "No working directory recorded for this session")
        XCTAssertEqual(resume.hint, "Open the transcript from Engram and copy the resume context manually.")
        XCTAssertEqual(resume.contextPrimer, "Resume context")
    }

    func testSQLiteReadProviderBuildsIncompleteResumePrimerFromMetadataWhenFtsIsMissing_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = 's1'")
        }
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
        XCTAssertEqual(resume.args, ["resume", "s1"])
        XCTAssertEqual(resume.cwd, "/tmp/engram")
        XCTAssertEqual(resume.contextPrimer, """
        Resume context from Engram archive:
        Session: s1
        Source: codex
        CWD: /tmp/engram

        Archived context:
        - Title: Generated Title
        - Project: engram
        - Model: gpt-5.4
        - Messages: 2 total, 1 user, 1 assistant, 0 tool
        - Transcript could not be read; this resume context is incomplete.
        """)
        XCTAssertNil(resume.error)
    }

    func testResumeCommandLabelsParserFailureInsteadOfClaimingCompleteMetadata_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = 's1'")
        }
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            commandLocator: { command in command == "codex" ? "/usr/local/bin/codex" : nil },
            transcriptPrimerReader: { _, _, _ in throw ParserFailure.malformedJSON }
        )

        let resume = try await provider.resumeCommand(.init(sessionId: "s1"))

        XCTAssertTrue(resume.contextPrimer?.contains("Title: Generated Title") ?? false)
        XCTAssertTrue(resume.contextPrimer?.contains("could not be read") ?? false)
        XCTAssertTrue(resume.contextPrimer?.contains("incomplete") ?? false)
    }

    func testResumeCommandRethrowsTranscriptCancellation_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = 's1'")
        }
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            transcriptPrimerReader: { _, _, _ in throw CancellationError() }
        )

        do {
            _ = try await provider.resumeCommand(.init(sessionId: "s1"))
            XCTFail("resume cancellation must not become a successful metadata primer")
        } catch is CancellationError {
            // expected
        }
    }

    func testResumeCommandUsesLocalReadablePathForRelocatedTranscript_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("relocated-s1.jsonl")
        try #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Recovered from local readable path"}]}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = 's1'")
            try db.execute(
                sql: "UPDATE sessions SET file_path = '/missing/original.jsonl' WHERE id = 's1'"
            )
            try db.execute(
                sql: "INSERT OR REPLACE INTO session_local_state(session_id, local_readable_path) VALUES ('s1', ?)",
                arguments: [transcript.path]
            )
        }
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            commandLocator: { command in command == "codex" ? "/usr/local/bin/codex" : nil }
        )

        let resume = try await provider.resumeCommand(.init(sessionId: "s1"))

        XCTAssertTrue(resume.contextPrimer?.contains("Recovered from local readable path") ?? false)
    }

    func testSQLiteReadProviderRedactsFtsResumePrimerExcerpts() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions_fts SET content = ? WHERE session_id = 's1'",
                arguments: ["Restore deployment with api_key=abcdef1234567890 before retry"]
            )
        }
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

        XCTAssertEqual(resume.contextPrimer, """
        Resume context from Engram archive:
        Session: s1
        Source: codex
        CWD: /tmp/engram

        Archived context:
        - Restore deployment with [REDACTED] before retry
        """)
        XCTAssertFalse(resume.contextPrimer?.contains("abcdef1234567890") ?? true)
        XCTAssertNil(resume.error)
    }

    func testSQLiteReadProviderBuildsResumePrimerFromRawTranscriptWhenFtsIsMissing() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("s1.jsonl")
        try """
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Please restore the checkout state with api_key=abcdef1234567890"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"I found the last edited file: Sources.swift"}]}}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET file_path = ? WHERE id = 's1'",
                arguments: [transcript.path]
            )
            try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = 's1'")
        }
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
        XCTAssertEqual(resume.args, ["resume", "s1"])
        XCTAssertEqual(resume.cwd, "/tmp/engram")
        XCTAssertEqual(resume.contextPrimer, """
        Resume context from Engram archive:
        Session: s1
        Source: codex
        CWD: /tmp/engram

        Archived context:
        - User: Please restore the checkout state with [REDACTED]
        - Assistant: I found the last edited file: Sources.swift
        """)
        XCTAssertNil(resume.error)
    }

    func testSQLiteReadProviderRawTranscriptPrimerKeepsOpeningPromptAndRecentMessages() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("s1.jsonl")
        try """
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Initial goal: stabilize resume context after a crash"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"Early filler 1"}]}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Early filler 2"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"Early filler 3"}]}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Recent decision: prefer transcript archive over metadata"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"Recent file: EngramServiceReadProvider.swift"}]}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Current verifier: run IPC resume tests"}]}}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET file_path = ? WHERE id = 's1'",
                arguments: [transcript.path]
            )
            try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = 's1'")
        }
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

        XCTAssertEqual(resume.contextPrimer, """
        Resume context from Engram archive:
        Session: s1
        Source: codex
        CWD: /tmp/engram

        Archived context:
        - User: Initial goal: stabilize resume context after a crash
        - User: Early filler 2
        - Assistant: Early filler 3
        - User: Recent decision: prefer transcript archive over metadata
        - Assistant: Recent file: EngramServiceReadProvider.swift
        - User: Current verifier: run IPC resume tests
        """)
        XCTAssertFalse(resume.contextPrimer?.contains("Early filler 1") ?? true)
        XCTAssertNil(resume.error)
    }

    func testSQLiteReadProviderRawTranscriptPrimerMarksOversizedTranscriptTruncation() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("s1.jsonl")
        var lines: [String] = []
        for index in 0..<10_020 {
            let role = index % 2 == 0 ? "user" : "assistant"
            let payloadRole = role == "user" ? "input_text" : "text"
            lines.append(
                #"{"type":"response_item","payload":{"type":"message","role":"\#(role)","content":[{"type":"\#(payloadRole)","text":"Oversized message \#(index)"}]}}"#
            )
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET file_path = ?, message_count = 10020 WHERE id = 's1'",
                arguments: [transcript.path]
            )
            try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = 's1'")
        }
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

        XCTAssertTrue(
            resume.contextPrimer?.contains("Transcript truncated at 10,000 messages") ?? false,
            resume.contextPrimer ?? ""
        )
        XCTAssertFalse(resume.contextPrimer?.contains("Oversized message 10019") ?? true)
        XCTAssertNil(resume.error)
    }

    func testSQLiteReadProviderFtsPrimerKeepsOpeningPromptAndRecentMessages() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = 's1'")
            for excerpt in [
                "Initial goal: stabilize resume context after a crash",
                "Early filler 1",
                "Early filler 2",
                "Early filler 3",
                "Recent decision: prefer FTS archive over metadata",
                "Recent file: EngramServiceReadProvider.swift",
                "Current verifier: run IPC resume tests"
            ] {
                try db.execute(
                    sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('s1', ?)",
                    arguments: [excerpt]
                )
            }
        }
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

        XCTAssertEqual(resume.contextPrimer, """
        Resume context from Engram archive:
        Session: s1
        Source: codex
        CWD: /tmp/engram

        Archived context:
        - Initial goal: stabilize resume context after a crash
        - Early filler 2
        - Early filler 3
        - Recent decision: prefer FTS archive over metadata
        - Recent file: EngramServiceReadProvider.swift
        - Current verifier: run IPC resume tests
        """)
        XCTAssertFalse(resume.contextPrimer?.contains("Early filler 1") ?? true)
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
        XCTAssertEqual(response.outputPath, exportHome.appendingPathComponent(".engram/exports/antigravity-legacy-s1-2026-04-23.json").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: response.outputPath))
        let exported = try String(contentsOfFile: response.outputPath, encoding: .utf8)
        XCTAssertTrue(exported.contains("hello"), exported)
        XCTAssertTrue(exported.contains("world"), exported)
        XCTAssertFalse(exported.contains("hidden legacy system"), exported)
        XCTAssertFalse(exported.contains("hidden agent comm"), exported)
    }

    func testExportSessionMarksTruncatedMarkdownAndJSONTranscripts_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("oversized-codex.jsonl")
        let lines = (0..<10_005).map { index in
            """
            {"timestamp":"2026-04-23T01:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"m\(index)"}]}}
            """
        }
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET source = 'codex', file_path = ?, message_count = 10005, user_message_count = 10005, assistant_message_count = 0, tool_message_count = 0 WHERE id = 's1'",
                arguments: [transcript.path]
            )
        }

        let exportHome = paths.runtime.appendingPathComponent("home", isDirectory: true)
        let homeScope = ServiceCoreTestHomeScope(home: exportHome)
        defer { homeScope.restore() }

        let markdown = try await TranscriptExportService.exportSession(
            EngramServiceExportSessionRequest(id: "s1", format: "markdown", outputHome: exportHome.path, actor: "test"),
            databasePath: paths.database.path
        )
        XCTAssertEqual(markdown.messageCount, 10_000)
        let markdownBody = try String(contentsOfFile: markdown.outputPath, encoding: .utf8)
        XCTAssertTrue(markdownBody.contains("**Messages:** 10005"), markdownBody)
        XCTAssertTrue(markdownBody.contains("Transcript truncated at 10,000 messages"), markdownBody)

        let json = try await TranscriptExportService.exportSession(
            EngramServiceExportSessionRequest(id: "s1", format: "json", outputHome: exportHome.path, actor: "test"),
            databasePath: paths.database.path
        )
        XCTAssertEqual(json.messageCount, 10_000)
        XCTAssertTrue(json.truncated)
        XCTAssertFalse(json.totalKnownComplete)
        XCTAssertEqual(json.truncatedAt, 10_000)
        XCTAssertNil(json.parseFailure)
        let data = try Data(contentsOf: URL(fileURLWithPath: json.outputPath))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let transcriptMetadata = try XCTUnwrap(payload["transcript"] as? [String: Any])
        XCTAssertEqual(transcriptMetadata["truncated"] as? Bool, true)
        XCTAssertEqual(transcriptMetadata["totalKnownComplete"] as? Bool, false)
        XCTAssertEqual(transcriptMetadata["truncatedAt"] as? Int, 10_000)
        XCTAssertEqual((payload["messages"] as? [[String: Any]])?.count, 10_000)
    }

    func testExportSessionMarksKimiOversizedTranscriptTruncated() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let sessionDir = paths.runtime.appendingPathComponent("kimi-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let transcript = sessionDir.appendingPathComponent("context.jsonl")
        let lines = (0..<10_005).map { index in
            """
            {"role":"user","content":"kimi \(index)","timestamp":"2026-04-23T01:00:01Z"}
            """
        }
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET source = 'kimi', file_path = ?, message_count = 10005, user_message_count = 10005, assistant_message_count = 0, tool_message_count = 0 WHERE id = 's1'",
                arguments: [transcript.path]
            )
        }

        let exportHome = paths.runtime.appendingPathComponent("home-kimi", isDirectory: true)
        let homeScope = ServiceCoreTestHomeScope(home: exportHome)
        defer { homeScope.restore() }

        let json = try await TranscriptExportService.exportSession(
            EngramServiceExportSessionRequest(id: "s1", format: "json", outputHome: exportHome.path, actor: "test"),
            databasePath: paths.database.path
        )

        try assertJSONExportMarkedTruncated(json)
    }

    func testExportSessionMarksOpenCodeOversizedTranscriptTruncatedWithArchiveResolverEnabled() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let opencodeDB = paths.runtime.appendingPathComponent("opencode.sqlite")
        let opencodeSessionId = "opencode-oversized"
        try seedOpenCodeOversizedTranscript(
            databasePath: opencodeDB.path,
            sessionId: opencodeSessionId,
            messageCount: 10_005
        )
        let locator = "\(opencodeDB.path)::\(opencodeSessionId)"

        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET source = 'opencode', file_path = ?, message_count = 10005, user_message_count = 10005, assistant_message_count = 0, tool_message_count = 0 WHERE id = 's1'",
                arguments: [locator]
            )
        }

        let exportHome = paths.runtime.appendingPathComponent("home-opencode", isDirectory: true)
        let homeScope = ServiceCoreTestHomeScope(home: exportHome)
        defer { homeScope.restore() }
        let archiveRoot = paths.runtime.appendingPathComponent("archive-opencode", isDirectory: true)
        let cas = try ImmutableArchiveCAS(root: archiveRoot)
        let catalog = try ArchiveCatalog(
            root: archiveRoot,
            machineID: "11111111-1111-4111-8111-111111111111"
        )
        try catalog.migrate()
        let replayParent = paths.runtime.appendingPathComponent("replay-opencode", isDirectory: true)
        try FileManager.default.createDirectory(
            at: replayParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolver = try ArchiveTranscriptResolver(
            catalog: catalog,
            cas: cas,
            temporaryParent: replayParent
        )

        let json = try await TranscriptExportService.exportSession(
            EngramServiceExportSessionRequest(id: "s1", format: "json", outputHome: exportHome.path, actor: "test"),
            databasePath: paths.database.path,
            archiveTranscriptResolver: resolver
        )

        try assertJSONExportMarkedTruncated(json)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: replayParent.path), [])
    }

    private func assertJSONExportMarkedTruncated(_ response: EngramServiceExportSessionResponse) throws {
        XCTAssertEqual(response.messageCount, 10_000)
        let data = try Data(contentsOf: URL(fileURLWithPath: response.outputPath))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let transcriptMetadata = try XCTUnwrap(payload["transcript"] as? [String: Any])
        XCTAssertEqual(transcriptMetadata["truncated"] as? Bool, true)
        XCTAssertEqual(transcriptMetadata["totalKnownComplete"] as? Bool, false)
        XCTAssertEqual(transcriptMetadata["truncatedAt"] as? Int, 10_000)
        XCTAssertEqual((payload["messages"] as? [[String: Any]])?.count, 10_000)
    }

    private func seedOpenCodeOversizedTranscript(
        databasePath: String,
        sessionId: String,
        messageCount: Int
    ) throws {
        let queue = try DatabaseQueue(path: databasePath)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE session (
                  id TEXT PRIMARY KEY,
                  directory TEXT,
                  title TEXT,
                  time_created REAL,
                  time_updated REAL,
                  time_archived REAL
                );
                CREATE TABLE message (
                  id TEXT PRIMARY KEY,
                  session_id TEXT,
                  time_created REAL,
                  data TEXT
                );
                CREATE TABLE part (
                  id TEXT PRIMARY KEY,
                  message_id TEXT,
                  time_created REAL,
                  data TEXT
                );
                INSERT INTO session (
                  id, directory, title, time_created, time_updated, time_archived
                ) VALUES (
                  ?, '/tmp/engram', 'Oversized OpenCode', 1776906000000, 1776906000000, NULL
                );
                """, arguments: [sessionId])
            for index in 0..<messageCount {
                let messageId = "message-\(index)"
                try db.execute(
                    sql: """
                        INSERT INTO message(id, session_id, time_created, data)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        messageId,
                        sessionId,
                        1_776_906_000_000 + index,
                        #"{"role":"user"}"#
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO part(id, message_id, time_created, data)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        "part-\(index)",
                        messageId,
                        1_776_906_000_000 + index,
                        #"{"type":"text","text":"opencode \#(index)"}"#
                    ]
                )
            }
        }
    }

    func testExportSessionRejectsOversizedGeminiJSONTranscript() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let transcript = paths.runtime.appendingPathComponent("oversized-gemini-session.json")
        let largeBody = String(repeating: "x", count: 512)
        try """
        {"messages":[{"type":"user","content":"\(largeBody)"}]}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET source = 'gemini-cli', file_path = ?, message_count = 1, user_message_count = 1, assistant_message_count = 0, tool_message_count = 0 WHERE id = 's1'",
                arguments: [transcript.path]
            )
        }

        let exportHome = paths.runtime.appendingPathComponent("home", isDirectory: true)
        let homeScope = ServiceCoreTestHomeScope(home: exportHome)
        defer { homeScope.restore() }
        setenv("ENGRAM_MAX_FULL_JSON_TRANSCRIPT_BYTES", "128", 1)
        defer { unsetenv("ENGRAM_MAX_FULL_JSON_TRANSCRIPT_BYTES") }

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
                EngramServiceExportSessionRequest(id: "s1", format: "json", outputHome: exportHome.path, actor: "test")
            )
            XCTFail("Oversized gemini-cli JSON transcripts must be rejected before export")
        } catch let error as EngramServiceError {
            // M12: size failures must preserve transcriptTooLarge, not collapse to invalidRequest.
            guard case .commandFailed(let name, let message, _, let details) = error else {
                return XCTFail("Expected commandFailed(transcriptTooLarge), got \(error)")
            }
            XCTAssertEqual(name, "transcriptTooLarge", "\(error)")
            if case .string(let code)? = details?["code"] {
                XCTAssertEqual(code, "transcriptTooLarge")
            }
            XCTAssertTrue(message.contains("gemini-cli transcript is too large"), message)
            XCTAssertFalse(message.contains(largeBody), "error must not echo transcript contents")
        }
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
            exportHome.appendingPathComponent(".engram/exports/antigravity-legacy-no-start-time-undated.md").path
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
        try FileManager.default.createDirectory(
            at: clientHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

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
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: serviceHome.appendingPathComponent(".engram/exports").path
            )
        )
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

    func testExportSessionRejectsExportsDirectorySymlink() async throws {
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
        let engramDir = serviceHome.appendingPathComponent(".engram", isDirectory: true)
        try FileManager.default.createDirectory(at: engramDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: engramDir.appendingPathComponent("exports", isDirectory: true),
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
            XCTFail("Expected invalidRequest for symlinked export directory")
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
        let outputDir = serviceHome
            .appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
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

        let linkedState = try fixtureLinkState(at: paths.database.path, id: "s2")
        XCTAssertEqual(linkedState.parentSessionId, "s1")
        XCTAssertNil(linkedState.suggestedParentId)
        XCTAssertEqual(linkedState.linkSource, "manual")

        try resetFixtureSuggestion(at: paths.database.path, id: "s2", suggestedParentId: "s1")

        try await client.dismissSuggestion(sessionId: "s2", suggestedParentId: "s1")
        let dismissedState = try fixtureLinkState(at: paths.database.path, id: "s2")
        XCTAssertNil(dismissedState.parentSessionId)
        XCTAssertNil(dismissedState.suggestedParentId)
    }

    func testManualParentLinkAndUnlinkRoundTripThroughClient() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        try setFixtureAmbiguousSuggestion(at: paths.database.path, id: "s2")
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
                sql: """
                    SELECT parent_session_id, suggested_parent_id, link_source,
                           suggestion_status, suggestion_candidates
                    FROM sessions WHERE id = 's2'
                """
            )
            XCTAssertEqual(row?["parent_session_id"] as String?, "s1")
            XCTAssertNil(row?["suggested_parent_id"] as String?)
            XCTAssertEqual(row?["link_source"] as String?, "manual")
            XCTAssertNil(row?["suggestion_status"] as String?)
            XCTAssertNil(row?["suggestion_candidates"] as String?)
        }

        let unlinked = try await client.clearParentSession(sessionId: "s2")
        XCTAssertEqual(unlinked, EngramServiceLinkResponse(ok: true, error: nil))

        let unlinkedState = try fixtureLinkState(at: paths.database.path, id: "s2")
        XCTAssertNil(unlinkedState.parentSessionId)
        XCTAssertEqual(unlinkedState.linkSource, "manual")
    }

    /// R2.P2.skip-parent-link-allowed: IPC must refuse linking under a skip parent.
    func testSetParentSessionRejectsSkipTierParent_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: """
                    UPDATE sessions
                    SET agent_role = 'dispatched', tier = 'skip'
                    WHERE id = 's1'
                    """
            )
        }

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

        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        )
        let linked = try await client.setParentSession(sessionId: "s2", parentId: "s1")
        XCTAssertEqual(linked.ok, false)
        XCTAssertEqual(linked.error, "parent-skip")

        try await queue.read { db in
            let parent = try String.fetchOne(
                db,
                sql: "SELECT parent_session_id FROM sessions WHERE id = 's2'"
            )
            XCTAssertNil(parent)
        }
    }

    /// Invariant 2 / R1-R2 P1: linking a dispatched/subagent child through the
    /// shipped IPC command must never upgrade it out of the skip tier.
    func testSetParentSessionPreservesSkipTier_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: """
                    UPDATE sessions
                    SET agent_role = 'subagent', tier = 'skip'
                    WHERE id = 's2'
                    """
            )
        }

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

        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        )
        let linked = try await client.setParentSession(sessionId: "s2", parentId: "s1")
        XCTAssertEqual(linked, EngramServiceLinkResponse(ok: true, error: nil))

        try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, link_source, agent_role, tier FROM sessions WHERE id = 's2'"
            )
            XCTAssertEqual(row?["parent_session_id"] as String?, "s1")
            XCTAssertEqual(row?["link_source"] as String?, "manual")
            XCTAssertEqual(row?["agent_role"] as String?, "subagent")
            XCTAssertEqual(row?["tier"] as String?, "skip")
        }
    }

    /// Wave 7B H05 (repro): clearParent through the shipped IPC handler must keep
    /// `dispatched` children at `tier=skip` (not NULL re-eval).
    func testClearParentPreservesDispatchedSkipTier_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: """
                    UPDATE sessions
                    SET parent_session_id = 's1',
                        link_source = 'path',
                        agent_role = 'dispatched',
                        tier = 'skip'
                    WHERE id = 's2'
                    """
            )
        }

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
        let unlinked = try await client.clearParentSession(sessionId: "s2")
        XCTAssertEqual(unlinked, EngramServiceLinkResponse(ok: true, error: nil))

        try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT parent_session_id, agent_role, tier, link_source
                    FROM sessions WHERE id = 's2'
                    """
            )
            XCTAssertNil(row?["parent_session_id"] as String?)
            XCTAssertEqual(row?["agent_role"] as String?, "dispatched")
            XCTAssertEqual(
                row?["tier"] as String?,
                "skip",
                "dispatched children must stay skip after clearParent (not NULL re-eval)"
            )
            XCTAssertEqual(row?["link_source"] as String?, "manual")
        }
    }

    func testDismissAmbiguousSuggestionRoundTripThroughClient() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        try setFixtureAmbiguousSuggestion(at: paths.database.path, id: "s2")
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

        let dismissed = try await client.dismissAmbiguousSuggestion(sessionId: "s2")
        XCTAssertEqual(dismissed, EngramServiceLinkResponse(ok: true, error: nil))
        let state = try fixtureLinkState(at: paths.database.path, id: "s2")
        XCTAssertNil(state.suggestionStatus)
        XCTAssertNil(state.suggestionCandidates)
        XCTAssertEqual(state.linkSource, "manual")
        XCTAssertNotNil(state.linkCheckedAt)

        let rejected = try await client.dismissAmbiguousSuggestion(sessionId: "s2")
        XCTAssertEqual(rejected, EngramServiceLinkResponse(ok: false, error: "not-ambiguous"))
    }

    /// Wave 7C H03 (repro): linkSessions stops between units and returns partial remaining.
    func testLinkSessionsCooperativeCancelReturnsRemaining_repro() throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let home = paths.runtime.appendingPathComponent("home", isDirectory: true)
        let sessionsDir = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let homeScope = ServiceCoreTestHomeScope(home: home)
        defer { homeScope.restore() }

        let queue = try DatabaseQueue(path: paths.database.path)
        // Point fixture rows at real files under the scoped home so path confinement allows them.
        try queue.write { db in
            for i in 1...6 {
                let file = sessionsDir.appendingPathComponent("rollout-\(i).jsonl")
                try "{}\n".write(to: file, atomically: true, encoding: .utf8)
                if i <= 2 {
                    try db.execute(
                        sql: "UPDATE sessions SET file_path = ? WHERE id = ?",
                        arguments: [file.path, "s\(i)"]
                    )
                } else {
                    try db.execute(
                        sql: """
                            INSERT INTO sessions (
                              id, source, start_time, cwd, project, model, message_count,
                              user_message_count, assistant_message_count, file_path, size_bytes,
                              indexed_at
                            ) VALUES (
                              ?, 'codex', '2026-04-23T10:0\(i):00Z', '/tmp/engram', 'engram',
                              'gpt-5.4', 1, 1, 0, ?, 10,
                              '2026-04-23T10:0\(i):00Z'
                            )
                            """,
                        arguments: ["s\(i)", file.path]
                    )
                }
            }
        }

        let target = home.appendingPathComponent("engram", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        var checks = 0
        let response = try EngramServiceCommandHandler.linkSessions(
            EngramServiceLinkSessionsRequest(targetDir: target.path, actor: "test"),
            databasePath: paths.database.path,
            shouldCancel: {
                checks += 1
                // Cancel after the first unit is observed (second check).
                return checks > 1
            }
        )

        XCTAssertEqual(response.cancelled, true)
        XCTAssertNotNil(response.remaining)
        XCTAssertGreaterThan(response.remaining ?? 0, 0)
        // At most one symlink unit completed before cancel (created or skipped/errors).
        XCTAssertLessThan(
            response.created + response.skipped + response.errors.count,
            6,
            "must not finish the full candidate set after cancel"
        )
    }

    func testLiveSessionsDoesNotDescendIntoExcludedClaudeSubagentCorpus_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("engram-live-claude-top-level-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent(".claude/projects/-tmp-engram", isDirectory: true)
        let subagents = project.appendingPathComponent("parent-session/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)

        let topLevel = project.appendingPathComponent("top-level.jsonl")
        try #"{"type":"user","sessionId":"top-level","cwd":"/tmp/engram"}"#.appending("\n")
            .write(to: topLevel, atomically: true, encoding: .utf8)
        let nested = subagents.appendingPathComponent("agent-nested.jsonl")
        try #"{"type":"user","sessionId":"nested","cwd":"/tmp/engram"}"#.appending("\n")
            .write(to: nested, atomically: true, encoding: .utf8)
        let now = Date()
        for file in [topLevel, nested] {
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        }

        let excludedVisitCount = LockedCounter()
        let response = try await FileSystemEngramServiceReadProvider(
            homeDirectory: root,
            liveSessionCacheTTL: 0,
            now: { now },
            liveSessionScanCheckpoint: { url in
                if url.path.contains("/subagents/") {
                    excludedVisitCount.increment()
                }
            }
        ).liveSessions()

        XCTAssertEqual(response.sessions.compactMap(\.sessionId), ["top-level"])
        XCTAssertEqual(
            excludedVisitCount.value,
            0,
            "Claude live scanning must not visit entries below a parent-session/subagents branch"
        )
    }

    func testLiveSessionsPropagatesCancellationFromRecursiveTraversal_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("engram-live-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent(".codex/sessions/2026/08/31", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let transcript = sessionDirectory.appendingPathComponent("rollout-cancel.jsonl")
        try #"{"type":"session_meta","payload":{"id":"cancelled"}}"#.appending("\n")
            .write(to: transcript, atomically: true, encoding: .utf8)

        let checkpoints = LockedCounter()
        let provider = FileSystemEngramServiceReadProvider(
            homeDirectory: root,
            liveSessionScanCheckpoint: { _ in
                checkpoints.increment()
                if checkpoints.value == 3 {
                    throw CancellationError()
                }
            }
        )

        do {
            _ = try await provider.liveSessions()
            XCTFail("Expected CancellationError from the recursive traversal checkpoint")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(checkpoints.value, 3, "Traversal must stop at the cancellation checkpoint")

        let retry = try await provider.liveSessions()
        XCTAssertEqual(retry.sessions.compactMap(\.sessionId), ["cancelled"])
        XCTAssertGreaterThan(checkpoints.value, 3, "A cancelled scan must not populate the live-session cache")
    }

    func testLiveSessionsCancellationDuringFinalizationThrowsAndDoesNotCache_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("engram-live-finalization-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent(".codex/sessions/2026/08/31", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let transcript = sessionDirectory.appendingPathComponent("rollout-finalization.jsonl")
        try #"{"type":"session_meta","payload":{"id":"finalization"}}"#.appending("\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: transcript.path)

        let finalizationEntered = DispatchSemaphore(value: 0)
        let finalizationRelease = DispatchSemaphore(value: 0)
        let finalizationCount = LockedCounter()
        let provider = FileSystemEngramServiceReadProvider(
            homeDirectory: root,
            now: { now },
            liveSessionFinalizationCheckpoint: {
                finalizationCount.increment()
                if finalizationCount.value == 1 {
                    finalizationEntered.signal()
                    finalizationRelease.wait()
                }
            }
        )

        let cancelledScan = Task { try await provider.liveSessions() }
        XCTAssertEqual(finalizationEntered.wait(timeout: .now() + 5), .success)
        cancelledScan.cancel()
        finalizationRelease.signal()

        do {
            _ = try await cancelledScan.value
            XCTFail("Expected CancellationError after candidate collection")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let retry = try await provider.liveSessions()
        XCTAssertEqual(retry.sessions.compactMap(\.sessionId), ["finalization"])
        XCTAssertEqual(finalizationCount.value, 2, "A cancelled finalization must not populate the cache")
    }

    func testLiveSessionsRejectsPreCancelledCacheHit_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("engram-live-cached-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent(".codex/sessions/2026/08/31", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let transcript = sessionDirectory.appendingPathComponent("rollout-cached.jsonl")
        try #"{"type":"session_meta","payload":{"id":"cached"}}"#.appending("\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: transcript.path)

        let provider = FileSystemEngramServiceReadProvider(homeDirectory: root, now: { now })
        _ = try await provider.liveSessions()

        let release = CheckpointTestSignal()
        let cancelledCacheHit = Task {
            await release.wait()
            return try await provider.liveSessions()
        }
        cancelledCacheHit.cancel()
        await release.signal()

        do {
            _ = try await cancelledCacheHit.value
            XCTFail("Expected CancellationError from a pre-cancelled cache hit")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testClaudeLiveScanFindsRecentSessionInsideOldMtimeProjectDirectory_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("engram-live-old-claude-project-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent(".claude/projects/-tmp-engram", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("recent.jsonl")
        try #"{"type":"user","sessionId":"recent-in-old-project","cwd":"/tmp/engram"}"#.appending("\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: transcript.path)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-2 * 24 * 60 * 60)],
            ofItemAtPath: project.path
        )

        let response = try await FileSystemEngramServiceReadProvider(
            homeDirectory: root,
            liveSessionCacheTTL: 0,
            now: { now }
        ).liveSessions()

        XCTAssertTrue(response.sessions.contains { $0.sessionId == "recent-in-old-project" })
    }

    func testFileSystemProviderReportsRecentlyModifiedLiveSessions() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-live-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root
            .appendingPathComponent(".codex/sessions/2026/05/24", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let sessionFile = sessionDir.appendingPathComponent("rollout-live.jsonl")
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

    func testLiveMetadataPrefersSessionKeysOverMessageIDs_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-live-ids-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let claudeDirectory = root.appendingPathComponent(".claude/projects/-tmp-engram", isDirectory: true)
        let geminiDirectory = root.appendingPathComponent(".gemini/tmp/engram/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiDirectory, withIntermediateDirectories: true)
        let claudeFile = claudeDirectory.appendingPathComponent("with-tools.jsonl")
        let geminiFile = geminiDirectory.appendingPathComponent("session-sample.json")
        try FileManager.default.copyItem(
            at: repository.appendingPathComponent("tests/fixtures/claude-code/with-tools.jsonl"),
            to: claudeFile
        )
        try FileManager.default.copyItem(
            at: repository.appendingPathComponent("tests/fixtures/gemini/session-sample.json"),
            to: geminiFile
        )
        for file in [claudeFile, geminiFile] {
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        }

        let response = try await FileSystemEngramServiceReadProvider(homeDirectory: root).liveSessions()
        let idsBySource = Dictionary(uniqueKeysWithValues: response.sessions.compactMap { session in
            session.sessionId.map { (session.source, $0) }
        })

        XCTAssertEqual(idsBySource["claude-code"], "tool-session-001")
        XCTAssertEqual(idsBySource["gemini-cli"], "gemini-session-001")
    }

    func testFileSystemProviderKeepsNewestLiveSessionsWhenCandidatesExceedLimit() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-live-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldDir = root
            .appendingPathComponent(".codex/sessions/a-old", isDirectory: true)
        let newDir = root
            .appendingPathComponent(".codex/sessions/z-new", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let oldBase = Date(timeIntervalSinceNow: -60 * 60)
        for index in 0..<105 {
            let id = String(format: "old-%03d", index)
            let file = oldDir.appendingPathComponent("rollout-\(id).jsonl")
            try """
            {"type":"session_meta","payload":{"id":"\(id)","cwd":"/tmp/old","model":"gpt-5"}}
            """.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: oldBase.addingTimeInterval(Double(index))],
                ofItemAtPath: file.path
            )
        }
        let newest = newDir.appendingPathComponent("rollout-zz-newest.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"newest","cwd":"/tmp/new","model":"gpt-5"}}
        """.write(to: newest, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: newest.path)

        let provider = FileSystemEngramServiceReadProvider(homeDirectory: root)
        let response = try await provider.liveSessions()

        XCTAssertEqual(response.sessions.count, 100)
        XCTAssertEqual(response.sessions.first?.sessionId, "newest")
        XCTAssertTrue(response.sessions.contains { $0.sessionId == "newest" })
        XCTAssertFalse(response.sessions.contains { $0.sessionId == "old-000" })
    }

    func testFileSystemProviderClassifiesLiveSubagentsRelativeToEachProjectsRoot_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-live-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root
            .appendingPathComponent(".claude/projects/-tmp-engram", isDirectory: true)
        let subagentDir = projectDir
            .appendingPathComponent("parent-session/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)

        // A real session directly under the project dir must be reported.
        let realSession = projectDir.appendingPathComponent("real.jsonl")
        try """
        {"type":"user","sessionId":"real-session","cwd":"/tmp/engram"}
        """.write(to: realSession, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: realSession.path)

        // A subagent transcript under /subagents/ is churn — it must be excluded.
        let subagentSession = subagentDir.appendingPathComponent("agent-abc.jsonl")
        try """
        {"type":"user","sessionId":"subagent-session","cwd":"/tmp/engram"}
        """.write(to: subagentSession, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: subagentSession.path)

        // docs/invariants.md #2: a custom projects root may itself contain a
        // `subagents` component. Its direct project session is still top-level.
        let customProjectsRoot = root
            .appendingPathComponent("custom/subagents/projects", isDirectory: true)
        let customProjectDir = customProjectsRoot
            .appendingPathComponent("-tmp-custom", isDirectory: true)
        try FileManager.default.createDirectory(at: customProjectDir, withIntermediateDirectories: true)
        let customSession = customProjectDir.appendingPathComponent("custom-top-level.jsonl")
        let customLines = (0..<20).map { index in
            let type = index.isMultiple(of: 2) ? "user" : "assistant"
            return #"{"type":"\#(type)","sessionId":"custom-top-level","cwd":"/tmp/custom"}"#
        }
        try customLines.joined(separator: "\n")
            .write(to: customSession, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: customSession.path)

        let settingsDirectory = root.appendingPathComponent(".engram", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settings = [
            "claudeCodeProfiles": [
                "autoDiscover": false,
                "customProjectsRoots": [customProjectsRoot.path],
            ] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: settings)
            .write(to: settingsDirectory.appendingPathComponent("settings.json"))

        let provider = FileSystemEngramServiceReadProvider(homeDirectory: root)
        let response = try await provider.liveSessions()

        let sessionIds = response.sessions.compactMap(\.sessionId)
        XCTAssertTrue(
            sessionIds.contains("real-session"),
            "A normal recent claude-code session must be reported as live"
        )
        XCTAssertFalse(
            sessionIds.contains("subagent-session"),
            "A validated default-root subagent transcript must be excluded from the live scan"
        )
        XCTAssertTrue(
            sessionIds.contains("custom-top-level"),
            "A top-level session under a custom projects root containing /subagents/ must stay live"
        )
    }

    func testLiveSessionEnumerationMatchesAdapterLocators_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("engram-live-locators-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let geminiChats = root.appendingPathComponent(".gemini/tmp/project/chats", isDirectory: true)
        let antigravityTranscript = root.appendingPathComponent(
            ".gemini/antigravity-cli/brain/brain-session/.system_generated/logs/transcript.jsonl"
        )
        let codexDirectory = root.appendingPathComponent(".codex/sessions/2026/08/22", isDirectory: true)
        let openCodeDatabase = root.appendingPathComponent(".local/share/opencode/opencode.db")
        for directory in [geminiChats, antigravityTranscript.deletingLastPathComponent(), codexDirectory,
                          openCodeDatabase.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let geminiSession = geminiChats.appendingPathComponent("session.json")
        try #"{"sessionId":"gemini-live","messages":[]}"#.write(
            to: geminiSession,
            atomically: true,
            encoding: .utf8
        )
        for sidecar in [
            geminiChats.appendingPathComponent("session.engram.json"),
            geminiChats.appendingPathComponent("logs.json"),
        ] {
            try #"{"sessionId":"must-not-appear"}"#.write(to: sidecar, atomically: true, encoding: .utf8)
        }
        try #"{"type":"message","sessionId":"transcript-must-not-win","content":"live"}"#.write(
            to: antigravityTranscript,
            atomically: true,
            encoding: .utf8
        )
        try #"{"sessionId":"metadata-must-not-appear"}"#.write(
            to: antigravityTranscript.deletingLastPathComponent().appendingPathComponent("metadata.json"),
            atomically: true,
            encoding: .utf8
        )
        let noIDCodex = codexDirectory.appendingPathComponent("filename-is-not-an-id.jsonl")
        try #"{"type":"message","content":"no explicit session identity"}"#.write(
            to: noIDCodex,
            atomically: true,
            encoding: .utf8
        )
        let codexSession = codexDirectory.appendingPathComponent("rollout-real-session.jsonl")
        try #"{"type":"message","content":"adapter-visible Codex transcript"}"#.write(
            to: codexSession,
            atomically: true,
            encoding: .utf8
        )

        let now = Date()
        do {
            let queue = try DatabaseQueue(path: openCodeDatabase.path)
            let recentMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
            let staleMilliseconds = recentMilliseconds - 30 * 24 * 3_600_000
            try await queue.write { db in
                try db.execute(sql: """
                    CREATE TABLE session (
                      id TEXT PRIMARY KEY,
                      directory TEXT,
                      title TEXT,
                      time_updated INTEGER NOT NULL,
                      time_archived INTEGER
                    );
                    INSERT INTO session (id, directory, title, time_updated, time_archived)
                    VALUES
                      ('opencode-live', '/repo/opencode', 'OpenCode live title', ?, NULL),
                      ('opencode-stale', '/repo/stale', 'Stale', ?, NULL),
                      ('archived', '/repo/archived', 'Archived', ?, 3);
                    """, arguments: [recentMilliseconds, staleMilliseconds, recentMilliseconds])
            }
        }

        for file in [geminiSession, antigravityTranscript, noIDCodex, codexSession] {
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-3_600)],
            ofItemAtPath: openCodeDatabase.path
        )

        let response = try await FileSystemEngramServiceReadProvider(
            homeDirectory: root,
            liveSessionCacheTTL: 0,
            now: { now }
        ).liveSessions()
        func canonicalLocator(_ locator: String) -> String {
            let parts = locator.components(separatedBy: "::")
            let path = URL(fileURLWithPath: parts[0]).resolvingSymlinksInPath().path
            return parts.count == 2 ? "\(path)::\(parts[1])" : path
        }
        let locators = Set(response.sessions.map { canonicalLocator($0.filePath) })
        let expected = Set([
            geminiSession.path,
            antigravityTranscript.path,
            codexSession.path,
            "\(openCodeDatabase.path)::opencode-live",
        ].map(canonicalLocator))

        XCTAssertEqual(locators, expected)
        XCTAssertTrue(response.sessions.allSatisfy { $0.id == $0.filePath })
        XCTAssertEqual(
            response.sessions.first { $0.source == "opencode" }?.sessionId,
            "opencode-live",
            "OpenCode must carry its source database primary key"
        )
        XCTAssertEqual(
            response.sessions.first {
                canonicalLocator($0.filePath) == canonicalLocator(antigravityTranscript.path)
            }?.sessionId,
            "brain-session",
            "Antigravity CLI live identity is the brain directory UUID"
        )
        XCTAssertFalse(
            locators.contains(canonicalLocator(noIDCodex.path)),
            "Codex live cards must use the same rollout-*.jsonl locators as CodexAdapter"
        )
    }

    func testAntigravityLiveCacheReadsMetadataOnlyFromFirstJSONObject_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("engram-live-antigravity-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent(".engram/cache/antigravity", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let transcript = cache.appendingPathComponent("cached.jsonl")
        try """
        {"sessionId":"cache-header-id"}
        {"sessionId":"later-id","title":"later title","cwd":"/later/path"}
        """.appending("\n").write(to: transcript, atomically: true, encoding: .utf8)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: transcript.path)

        let response = try await FileSystemEngramServiceReadProvider(
            homeDirectory: root,
            liveSessionCacheTTL: 0,
            now: { now }
        ).liveSessions()
        let session = try XCTUnwrap(response.sessions.first)

        XCTAssertEqual(session.sessionId, "cache-header-id")
        XCTAssertNil(session.title)
        XCTAssertNil(session.cwd)
    }

    func testAntigravityBrainLiveIdentityWinsWhenFirstLineIsNotJSON_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("engram-live-antigravity-explicit-id-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent(
            ".gemini/antigravity-cli/brain/brain-uuid/.system_generated/logs/transcript.jsonl"
        )
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        truncated-prefix
        {"sessionId":"body-id-must-not-win","title":"Live work"}
        """.appending("\n").write(to: transcript, atomically: true, encoding: .utf8)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: transcript.path)

        let response = try await FileSystemEngramServiceReadProvider(
            homeDirectory: root,
            liveSessionCacheTTL: 0,
            now: { now }
        ).liveSessions()

        XCTAssertEqual(try XCTUnwrap(response.sessions.first).sessionId, "brain-uuid")
    }

    func testAntigravityLiveScanCoversEveryDocumentedBrainRoot_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("engram-live-antigravity-roots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = [
            ".gemini/antigravity-cli/brain",
            ".gemini/antigravity/brain",
            ".gemini/antigravity-ide/brain",
        ]
        let now = Date()
        for (index, relativeRoot) in roots.enumerated() {
            let transcript = root.appendingPathComponent(
                "\(relativeRoot)/brain-\(index)/.system_generated/logs/transcript.jsonl"
            )
            try FileManager.default.createDirectory(
                at: transcript.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "not-json\n".write(to: transcript, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: transcript.path)
        }

        let response = try await FileSystemEngramServiceReadProvider(
            homeDirectory: root,
            liveSessionCacheTTL: 0,
            now: { now }
        ).liveSessions()

        XCTAssertEqual(Set(response.sessions.compactMap(\.sessionId)), Set(["brain-0", "brain-1", "brain-2"]))
    }

    func testLiveScanSkipsDirectorySymlinkChildren_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("engram-live-linked-dir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent(".codex/sessions", isDirectory: true)
        let physical = root.appendingPathComponent("physical-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: sessions.appendingPathComponent("linked", isDirectory: true),
            withDestinationURL: physical
        )
        let transcript = physical.appendingPathComponent("rollout-linked.jsonl")
        try #"{"type":"session_meta","payload":{"id":"linked-live"}}"#.appending("\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: transcript.path)

        let response = try await FileSystemEngramServiceReadProvider(
            homeDirectory: root,
            liveSessionCacheTTL: 0,
            now: { now }
        ).liveSessions()

        XCTAssertFalse(
            response.sessions.contains { $0.sessionId == "linked-live" },
            "live sessions: \(response.sessions)"
        )
    }

    func testOpenCodeLiveScanAcceptsSymlinkToRegularDatabase_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("engram-live-opencode-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let physical = root.appendingPathComponent("physical-opencode.db")
        let link = root.appendingPathComponent(".local/share/opencode/opencode.db")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Date()
        let updated = Int64(now.timeIntervalSince1970 * 1_000)
        try await DatabaseQueue(path: physical.path).write { db in
            try db.execute(sql: """
                CREATE TABLE session (
                  id TEXT PRIMARY KEY, directory TEXT, title TEXT,
                  time_updated INTEGER NOT NULL, time_archived INTEGER
                );
                INSERT INTO session VALUES ('linked-opencode', '/repo', 'Linked', ?, NULL);
                """, arguments: [updated])
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: physical)

        let response = try await FileSystemEngramServiceReadProvider(
            homeDirectory: root,
            liveSessionCacheTTL: 0,
            now: { now }
        ).liveSessions()

        XCTAssertTrue(response.sessions.contains { $0.sessionId == "linked-opencode" })
    }

    func testMissingAntigravityTranscriptDoesNotAbortOtherLiveSources_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("engram-live-missing-antigravity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingBrain = root.appendingPathComponent(
            ".gemini/antigravity-cli/brain/missing/.system_generated/logs",
            isDirectory: true
        )
        let codexDirectory = root.appendingPathComponent(".codex/sessions/2026/08/23", isDirectory: true)
        try FileManager.default.createDirectory(at: missingBrain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let codex = codexDirectory.appendingPathComponent("rollout-survives.jsonl")
        try #"{"type":"session_meta","payload":{"id":"codex-survives"}}"#.write(
            to: codex,
            atomically: true,
            encoding: .utf8
        )
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: codex.path)

        let response = try await FileSystemEngramServiceReadProvider(
            homeDirectory: root,
            liveSessionCacheTTL: 0,
            now: { now }
        ).liveSessions()

        XCTAssertEqual(response.sessions.map(\.sessionId), ["codex-survives"])
    }

    func testOpenCodeLiveCardsUseRowMetadataWithoutParsingTheDatabaseBlob_repro() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("engram-live-opencode-metadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent(".local/share/opencode/opencode.db")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let now = Date()
        let queue = try DatabaseQueue(path: databaseURL.path)
        try await queue.write { database in
            try database.execute(sql: """
                CREATE TABLE session (
                  id TEXT PRIMARY KEY,
                  directory TEXT,
                  title TEXT,
                  time_updated INTEGER NOT NULL,
                  time_archived INTEGER
                );
                INSERT INTO session (id, directory, title, time_updated, time_archived)
                VALUES ('open-live', '/repo/from-row', 'Title from row', ?, NULL);
                """, arguments: [Int64(now.timeIntervalSince1970 * 1_000)])
        }

        let response = try await FileSystemEngramServiceReadProvider(
            homeDirectory: root,
            liveSessionCacheTTL: 0,
            now: { now }
        ).liveSessions()
        let session = try XCTUnwrap(response.sessions.first { $0.source == "opencode" })

        XCTAssertEqual(session.sessionId, "open-live")
        XCTAssertEqual(session.title, "Title from row")
        XCTAssertEqual(session.cwd, "/repo/from-row")
    }

    func testPeriodicRepoDiscoveryRefreshesCountsOnIdleCycles_repro() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let cycle = try XCTUnwrap(source.range(of: "private static func runOnePeriodicIndexCycle("))
        let helper = try XCTUnwrap(source.range(of: "static func refreshRepoDiscovery("))
        let body = String(source[cycle.lowerBound..<helper.lowerBound])
        XCTAssertTrue(body.contains("let repoCount = try await refreshRepoDiscovery("))
        XCTAssertFalse(body.contains("if scan.indexed > 0 {\n                let repoCandidates"))
        XCTAssertTrue(
            source.contains("throttle: RepoDiscoveryMaintenanceThrottle = .shared")
                && source.contains("throttle.selectCandidates(")
                && source.contains("forcedCwds: snapshot.1"),
            "repo probing must pass through the bounded maintenance throttle"
        )
        XCTAssertTrue(
            source.contains("probeRepositoriesDetailed")
                && source.contains("recordOutcomes("),
            "repo probing must record success/failure after the probe, not at selection"
        )
    }

    func testLiveSessionsStreamsEnumeratorInsteadOfMaterializingFullTree() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceReadProvider.swift")
        let start = try XCTUnwrap(source.range(of: "private func scanLiveSessions(now: Date)"))
        let end = try XCTUnwrap(source.range(of: "private struct LiveMetadata"))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(
            body.contains("compactMap { $0 as? URL }"),
            "liveSessions must not materialize the full directory tree before applying the result cap"
        )
        XCTAssertTrue(
            body.contains("enumerateLiveFiles") && source.contains("directChildren(of:"),
            "liveSessions should stream one directory at a time while following safe directory symlinks"
        )
    }

    func testFileSystemProviderCachesLiveSessionsAcrossMenuCadence() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-live-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root
            .appendingPathComponent(".codex/sessions/2026/05/24", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let first = sessionDir.appendingPathComponent("rollout-first.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"first","cwd":"/tmp/engram","model":"gpt-5"}}
        """.write(to: first, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: first.path)

        let provider = FileSystemEngramServiceReadProvider(homeDirectory: root)
        let initial = try await provider.liveSessions()
        let second = sessionDir.appendingPathComponent("rollout-second.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"second","cwd":"/tmp/engram","model":"gpt-5"}}
        """.write(to: second, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: second.path)

        let cached = try await provider.liveSessions()

        XCTAssertEqual(initial.sessions.map(\.sessionId), ["first"])
        XCTAssertEqual(
            cached.sessions.map(\.sessionId),
            ["first"],
            "liveSessions should reuse a short-lived cache instead of rescanning on every 10s menu tick"
        )
    }

    func testFileSystemProviderLiveSessionCacheExpiresAfterTTL() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-live-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root
            .appendingPathComponent(".codex/sessions/2026/05/24", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let clock = ManualDateProvider(Date())
        let first = sessionDir.appendingPathComponent("rollout-first.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"first","cwd":"/tmp/engram","model":"gpt-5"}}
        """.write(to: first, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: clock.now()], ofItemAtPath: first.path)

        let provider = FileSystemEngramServiceReadProvider(
            homeDirectory: root,
            liveSessionCacheTTL: 30,
            now: clock.now
        )
        let initial = try await provider.liveSessions()
        XCTAssertEqual(initial.sessions.map(\.sessionId), ["first"])

        let second = sessionDir.appendingPathComponent("rollout-second.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"second","cwd":"/tmp/engram","model":"gpt-5"}}
        """.write(to: second, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: clock.now()], ofItemAtPath: second.path)

        // Within TTL: the cache still serves the pre-second snapshot.
        clock.advance(by: 29)
        let cachedWithinTTL = try await provider.liveSessions()
        XCTAssertEqual(
            cachedWithinTTL.sessions.map(\.sessionId),
            ["first"],
            "live-session cache must serve within the TTL window"
        )

        // Past TTL: the cache expires and a fresh scan picks up the new file.
        clock.advance(by: 2)
        let refreshed = try await provider.liveSessions()
        XCTAssertEqual(
            Set(refreshed.sessions.map(\.sessionId)),
            ["first", "second"],
            "live-session cache must expire after TTL and rescan the filesystem"
        )
    }

    func testFileSystemProviderKeepsActiveSessionFromAnotherSourceUnderGlobalCap() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-live-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codexDir = root.appendingPathComponent(".codex/sessions/2026/05/24", isDirectory: true)
        let claudeDir = root.appendingPathComponent(".claude/projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Flood one source with 105 recent-but-older files (idle/recent tier).
        let base = Date(timeIntervalSinceNow: -30 * 60)
        for index in 0..<105 {
            let id = String(format: "codex-%03d", index)
            let file = codexDir.appendingPathComponent("rollout-\(id).jsonl")
            try """
            {"type":"session_meta","payload":{"id":"\(id)","cwd":"/tmp/codex","model":"gpt-5"}}
            """.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: base.addingTimeInterval(Double(index))],
                ofItemAtPath: file.path
            )
        }
        // A single genuinely active (newest) session in a DIFFERENT source.
        let active = claudeDir.appendingPathComponent("active.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"active-claude","cwd":"/tmp/claude","model":"claude"}}
        """.write(to: active, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: active.path)

        let provider = FileSystemEngramServiceReadProvider(homeDirectory: root)
        let response = try await provider.liveSessions()

        // The global 100-cap keeps the newest-by-mtime across ALL sources, so a
        // source flooding 100+ recent files must not crowd out a newer active
        // session from another source.
        XCTAssertEqual(response.sessions.count, 100)
        XCTAssertEqual(response.sessions.first?.sessionId, "active-claude")
        XCTAssertTrue(
            response.sessions.contains { $0.sessionId == "active-claude" && $0.activityLevel == "active" },
            "the newest active session must survive the global cap even when another source floods it"
        )
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

    func testHideEmptySessionsIgnoresSkipTierRows_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE sessions SET message_count = 0, size_bytes = 512 WHERE id = 's2'")
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, message_count, file_path,
                  size_bytes, indexed_at, tier
                ) VALUES (
                  'skip-empty', 'codex', '2026-04-23T03:00:00Z', '/tmp/engram', 'engram', 0,
                  '/tmp/skip-empty.jsonl', 100, '2026-04-23T03:00:00Z', 'skip'
                )
                """)
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

            let skipHidden = try String.fetchOne(
                db,
                sql: "SELECT hidden_at FROM sessions WHERE id = 'skip-empty'"
            )
            XCTAssertNil(skipHidden)

            let localHidden = try String.fetchOne(
                db,
                sql: "SELECT hidden_at FROM session_local_state WHERE session_id = 's1'"
            )
            XCTAssertNil(localHidden)
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

    func testHygieneHideSurvivesSourceDisableEnable_repro() async throws {
        let settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-hygiene-hide-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        let seedData = try JSONSerialization.data(withJSONObject: [
            "disabledSources": [] as [String],
            ArchivedDefaultOffSources.settingsMigrationKey: true,
        ])
        try seedData.write(to: settingsURL)
        setenv("ENGRAM_SETTINGS_PATH", settingsURL.path, 1)
        defer {
            unsetenv("ENGRAM_SETTINGS_PATH")
            try? FileManager.default.removeItem(at: settingsDirectory)
        }

        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        let source = try await queue.write { db -> String in
            try db.execute(sql: "UPDATE sessions SET message_count = 0, size_bytes = 512 WHERE id = 's2'")
            return try String.fetchOne(db, sql: "SELECT source FROM sessions WHERE id = 's2'") ?? "codex"
        }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }
        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))

        let hidden = try await client.hideEmptySessions()
        XCTAssertEqual(hidden.hiddenCount, 1)
        try await client.setSourceEnabled(source: source, enabled: false)
        try await client.setSourceEnabled(source: source, enabled: true)

        let row = try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT s.hidden_at, ls.hidden_at AS local_hidden_at
                    FROM sessions s
                    LEFT JOIN session_local_state ls ON ls.session_id = s.id
                    WHERE s.id = 's2'
                """
            )
        }
        XCTAssertNotNil(row?["hidden_at"] as String?)
        XCTAssertNotNil(row?["local_hidden_at"] as String?)
    }

    func testSetFavoriteWritesCreatedAtForLegacySchemaWithoutDefault_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS favorites")
            try db.execute(sql: """
                CREATE TABLE favorites (
                    session_id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL
                )
                """)
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

        try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT session_id, created_at FROM favorites WHERE session_id = 's1'"
            )
            XCTAssertEqual(row?["session_id"] as String?, "s1")
            XCTAssertFalse((row?["created_at"] as String? ?? "").isEmpty)
        }
    }

    func testSetSessionHiddenMirrorsLocalState() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        try await client.setSessionHidden(sessionId: "s1", hidden: true)

        try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT s.hidden_at AS session_hidden_at, ls.hidden_at AS local_hidden_at
                    FROM sessions s
                    LEFT JOIN session_local_state ls ON ls.session_id = s.id
                    WHERE s.id = 's1'
                """
            )
            let sessionHiddenAt = row?["session_hidden_at"] as String?
            let localHiddenAt = row?["local_hidden_at"] as String?
            XCTAssertNotNil(sessionHiddenAt)
            XCTAssertEqual(localHiddenAt, sessionHiddenAt)
        }
    }

    func testSetSessionHiddenRejectsMissingSession() async throws {
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
            try await client.setSessionHidden(sessionId: "missing-session", hidden: true)
            XCTFail("Expected missing session to fail")
        } catch let error as EngramServiceError {
            guard case .commandFailed(let name, let message, _, let details) = error else {
                return XCTFail("Expected commandFailed, got \(error)")
            }
            XCTAssertEqual(name, "SessionNotFound")
            XCTAssertEqual(message, "session-not-found")
            XCTAssertEqual(details?["session_id"], .string("missing-session"))
        }
    }

    func testSetSourceEnabledTogglesIngestHidesSessionsAndPreservesSettings() async throws {
        // Feature #2 slice B round-trip via a temp settings.json. ENGRAM_SETTINGS_PATH
        // points both the write (RMW) and read (disabledSources) paths at the temp file.
        let settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-settings-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        let seed: [String: Any] = [
            "customSetting": true,
            "aiModel": "gpt-4o-mini",
            "disabledSources": [],
            ArchivedDefaultOffSources.settingsMigrationKey: true,
        ]
        let seedData = try JSONSerialization.data(withJSONObject: seed)
        try seedData.write(to: settingsURL)
        setenv("ENGRAM_SETTINGS_PATH", settingsURL.path, 1)
        defer {
            unsetenv("ENGRAM_SETTINGS_PATH")
            try? FileManager.default.removeItem(at: settingsDirectory)
        }

        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))

        // DISABLE codex (the seed fixture's only source): disabledSources contains
        // it and its sessions are hidden.
        try await client.setSourceEnabled(source: "codex", enabled: false)
        let afterDisable = try await client.disabledSources()
        XCTAssertTrue(afterDisable.contains("codex"))

        let hiddenCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE source = 'codex' AND hidden_at IS NOT NULL") ?? 0
        }
        XCTAssertEqual(hiddenCount, 2, "both seeded codex sessions must be hidden on disable")

        // RMW preserved the pre-existing unrelated keys.
        let preservedAfterDisable = try loadSettings(settingsURL)
        XCTAssertEqual(preservedAfterDisable["customSetting"] as? Bool, true)
        XCTAssertEqual(preservedAfterDisable["aiModel"] as? String, "gpt-4o-mini")
        XCTAssertEqual(preservedAfterDisable["disabledSources"] as? [String], ["codex"])
        XCTAssertEqual(preservedAfterDisable[ArchivedDefaultOffSources.settingsMigrationKey] as? Bool, true)

        // ENABLE codex: removed from disabledSources and sessions unhidden.
        try await client.setSourceEnabled(source: "codex", enabled: true)
        let afterEnable = try await client.disabledSources()
        XCTAssertFalse(afterEnable.contains("codex"))

        let stillHidden = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE source = 'codex' AND hidden_at IS NOT NULL") ?? 0
        }
        XCTAssertEqual(stillHidden, 0, "enabling must unhide the source's sessions")

        let preservedAfterEnable = try loadSettings(settingsURL)
        XCTAssertEqual(preservedAfterEnable["customSetting"] as? Bool, true)
        XCTAssertEqual(preservedAfterEnable["aiModel"] as? String, "gpt-4o-mini")
        XCTAssertEqual(preservedAfterEnable["disabledSources"] as? [String], [])
        XCTAssertEqual(preservedAfterEnable[ArchivedDefaultOffSources.settingsMigrationKey] as? Bool, true)
    }

    /// R2.P1.source-enable-hide-clobber — re-enable must not clear user manual hides.
    func testSetSourceEnabledPreservesManualHideOnEnable_repro() async throws {
        let settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-source-manual-hide-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        let seed: [String: Any] = [
            "customSetting": true,
            "disabledSources": [] as [String],
            ArchivedDefaultOffSources.settingsMigrationKey: true,
        ]
        let seedData = try JSONSerialization.data(withJSONObject: seed)
        try seedData.write(to: settingsURL)
        setenv("ENGRAM_SETTINGS_PATH", settingsURL.path, 1)
        defer {
            unsetenv("ENGRAM_SETTINGS_PATH")
            try? FileManager.default.removeItem(at: settingsDirectory)
        }

        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))

        // Manually hide one seeded session (writes sessions + session_local_state).
        let manualId = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM sessions WHERE source = 'codex' ORDER BY id LIMIT 1")
        }
        XCTAssertNotNil(manualId)
        try await client.setSessionHidden(sessionId: manualId!, hidden: true)

        try await client.setSourceEnabled(source: "codex", enabled: false)
        try await client.setSourceEnabled(source: "codex", enabled: true)

        let manualStillHidden = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT hidden_at FROM sessions WHERE id = ?",
                arguments: [manualId!]
            )
        }
        XCTAssertNotNil(manualStillHidden, "manual hide must survive source disable/enable cycle")

        let localHidden = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT hidden_at FROM session_local_state WHERE session_id = ?",
                arguments: [manualId!]
            )
        }
        XCTAssertNotNil(localHidden, "session_local_state.hidden_at must remain set for manual hide")
    }

    /// R1/R2 P1 settings-db-split: a rejected SQLite mutation must not leave
    /// settings.json claiming the source is disabled while its rows remain live.
    func testSetSourceEnabledDatabaseFailureLeavesSettingsUnchanged_repro() async throws {
        let settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-source-atomicity-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        let seed: [String: Any] = [
            "customSetting": true,
            "disabledSources": [] as [String],
            ArchivedDefaultOffSources.settingsMigrationKey: true,
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: settingsURL)
        setenv("ENGRAM_SETTINGS_PATH", settingsURL.path, 1)
        defer {
            unsetenv("ENGRAM_SETTINGS_PATH")
            try? FileManager.default.removeItem(at: settingsDirectory)
        }

        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER reject_source_disable
                    BEFORE UPDATE OF hidden_at ON sessions
                    WHEN NEW.source = 'codex' AND NEW.hidden_at IS NOT NULL
                    BEGIN
                        SELECT RAISE(ABORT, 'forced-source-toggle-failure');
                    END
                    """
            )
        }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        )
        do {
            try await client.setSourceEnabled(source: "codex", enabled: false)
            XCTFail("forced SQLite failure must fail the source toggle")
        } catch {
            // Expected: the assertion below verifies cross-store rollback.
        }

        let persisted = try loadSettings(settingsURL)
        XCTAssertEqual(persisted["disabledSources"] as? [String], [])
        XCTAssertEqual(persisted["customSetting"] as? Bool, true)
        let hiddenCount = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sessions WHERE source = 'codex' AND hidden_at IS NOT NULL"
            ) ?? 0
        }
        XCTAssertEqual(hiddenCount, 0)
    }

    /// R1/R2 P1 settings-db-split: SQLite may reject COMMIT only after the
    /// settings rename. The service must compensate the source membership and
    /// let the failed database transaction roll back.
    func testSetSourceEnabledCommitFailureCompensatesSettings_repro() async throws {
        let settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-source-commit-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        let seed: [String: Any] = [
            "customSetting": true,
            "disabledSources": [] as [String],
            ArchivedDefaultOffSources.settingsMigrationKey: true,
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: settingsURL)
        setenv("ENGRAM_SETTINGS_PATH", settingsURL.path, 1)
        defer {
            unsetenv("ENGRAM_SETTINGS_PATH")
            try? FileManager.default.removeItem(at: settingsDirectory)
        }

        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE source_toggle_parent (id INTEGER PRIMARY KEY);
                    CREATE TABLE source_toggle_commit_guard (
                        parent_id INTEGER,
                        FOREIGN KEY (parent_id) REFERENCES source_toggle_parent(id)
                            DEFERRABLE INITIALLY DEFERRED
                    );
                    CREATE TRIGGER reject_source_disable_commit
                    AFTER UPDATE OF hidden_at ON sessions
                    WHEN NEW.source = 'codex' AND NEW.hidden_at IS NOT NULL
                    BEGIN
                        INSERT INTO source_toggle_commit_guard(parent_id) VALUES (999);
                    END;
                    """
            )
        }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        )
        do {
            try await client.setSourceEnabled(source: "codex", enabled: false)
            XCTFail("deferred foreign-key failure must reject the source toggle at commit")
        } catch {
            // Expected: durable state assertions below prove compensation.
        }

        let persisted = try loadSettings(settingsURL)
        XCTAssertEqual(persisted["disabledSources"] as? [String], [])
        XCTAssertEqual(persisted["customSetting"] as? Bool, true)
        try await queue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sessions WHERE source = 'codex' AND hidden_at IS NOT NULL"
                ),
                0
            )
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source_toggle_commit_guard"), 0)
        }
    }

    /// R1/R2 P1 settings-db-split: a crash after the atomic settings rename
    /// but before SQLite commit leaves a durable intent. Startup must replay it
    /// idempotently, including the enable path's manual-hide exception.
    func testPendingSourceVisibilityIntentReconcilesAfterRestart_repro() async throws {
        let settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-source-intent-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: settingsDirectory) }

        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)

        let pendingDisable: [String: Any] = [
            "disabledSources": ["codex"],
            ArchivedDefaultOffSources.settingsMigrationKey: true,
            "sourceVisibilityIntent": ["source": "codex", "enabled": false],
        ]
        try JSONSerialization.data(withJSONObject: pendingDisable).write(to: settingsURL)
        try await gate.performWriteCommand(name: "reconcilePendingSourceDisable") { writer in
            try EngramServiceCommandHandler.reconcilePendingSourceVisibilityIntent(
                writer: writer,
                settingsURL: settingsURL
            )
        }.value

        let sessionIDs = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM sessions WHERE source = 'codex' ORDER BY id")
        }
        XCTAssertEqual(sessionIDs.count, 2)
        try await queue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sessions WHERE source = 'codex' AND hidden_at IS NOT NULL"
                ),
                2
            )
        }
        XCTAssertNil(try loadSettings(settingsURL)["sourceVisibilityIntent"])

        let manualID = try XCTUnwrap(sessionIDs.first)
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO session_local_state (session_id, hidden_at)
                    VALUES (?, datetime('now'))
                    ON CONFLICT(session_id) DO UPDATE SET hidden_at = excluded.hidden_at
                    """,
                arguments: [manualID]
            )
        }
        let pendingEnable: [String: Any] = [
            "disabledSources": [] as [String],
            ArchivedDefaultOffSources.settingsMigrationKey: true,
            "sourceVisibilityIntent": ["source": "codex", "enabled": true],
        ]
        try JSONSerialization.data(withJSONObject: pendingEnable).write(to: settingsURL)
        try await gate.performWriteCommand(name: "reconcilePendingSourceEnable") { writer in
            try EngramServiceCommandHandler.reconcilePendingSourceVisibilityIntent(
                writer: writer,
                settingsURL: settingsURL
            )
        }.value

        try await queue.read { db in
            XCTAssertNotNil(
                try String.fetchOne(
                    db,
                    sql: "SELECT hidden_at FROM sessions WHERE id = ?",
                    arguments: [manualID]
                )
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sessions WHERE source = 'codex' AND hidden_at IS NOT NULL"
                ),
                1
            )
        }
        XCTAssertNil(try loadSettings(settingsURL)["sourceVisibilityIntent"])
    }

    func testReadDisabledSourcesFiltersAdapterListWithoutAffectingOthers() {
        // ENGRAM_DISABLED_SOURCES env override drives readDisabledSources; the
        // filtered adapter list drops only the disabled source.
        let disabled = EngramServiceRunner.readDisabledSources(
            environment: ["ENGRAM_DISABLED_SOURCES": "codex, windsurf"]
        )
        XCTAssertEqual(disabled, ["codex", "windsurf"])

        let all = SessionAdapterFactory.defaultAdapters()
        let enabled = all.filter { !disabled.contains($0.source.rawValue) }
        XCTAssertEqual(enabled.count, all.count - 2)
        let enabledIDs = Set(enabled.map { $0.source.rawValue })
        XCTAssertFalse(enabledIDs.contains("codex"))
        XCTAssertFalse(enabledIDs.contains("windsurf"))
        XCTAssertTrue(enabledIDs.contains("claude-code"), "non-disabled sources must survive the filter")
        XCTAssertTrue(enabledIDs.contains("gemini-cli"))
    }

    func testReadDisabledSourcesDefaultsArchivedSourcesOffWhenUnset() throws {
        let settingsURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("engram-missing-settings-\(UUID().uuidString.prefix(8)).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let disabled = EngramServiceRunner.readDisabledSources(
            environment: [:],
            settingsURL: settingsURL
        )

        XCTAssertEqual(disabled, ArchivedDefaultOffSources.ids)
        XCTAssertEqual(disabled, ["cline", "iflow", "lobsterai"])
        XCTAssertFalse(disabled.contains("minimax"), "minimax must stay active by default")
    }

    func testReadDisabledSourcesTreatsLegacyEmptyListAsArchivedDefaults() throws {
        let fixture = try makePrivateSettingsFixture()
        let data = try JSONSerialization.data(withJSONObject: ["disabledSources": []])
        try data.write(to: fixture.settingsURL)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let disabled = EngramServiceRunner.readDisabledSources(
            environment: [:],
            settingsURL: fixture.settingsURL
        )

        XCTAssertEqual(disabled, ArchivedDefaultOffSources.ids)
    }

    func testReadDisabledSourcesMergesArchivedDefaultsIntoLegacyList() throws {
        let fixture = try makePrivateSettingsFixture()
        let data = try JSONSerialization.data(withJSONObject: ["disabledSources": ["codex"]])
        try data.write(to: fixture.settingsURL)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let disabled = EngramServiceRunner.readDisabledSources(
            environment: [:],
            settingsURL: fixture.settingsURL
        )

        XCTAssertEqual(disabled, ArchivedDefaultOffSources.ids.union(["codex"]))
    }

    func testReadDisabledSourcesHonorsMigratedExplicitEmptyList() throws {
        let fixture = try makePrivateSettingsFixture()
        let data = try JSONSerialization.data(
            withJSONObject: [
                "disabledSources": [],
                ArchivedDefaultOffSources.settingsMigrationKey: true,
            ]
        )
        try data.write(to: fixture.settingsURL)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let disabled = EngramServiceRunner.readDisabledSources(
            environment: [:],
            settingsURL: fixture.settingsURL
        )

        XCTAssertEqual(disabled, [], "a migrated explicit empty list means the user enabled every source")
    }

    func testSetSourceEnabledStartsFromImplicitArchivedDefaults() async throws {
        let settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-settings-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        let seedData = try JSONSerialization.data(withJSONObject: ["customSetting": true])
        try seedData.write(to: settingsURL)
        setenv("ENGRAM_SETTINGS_PATH", settingsURL.path, 1)
        defer {
            unsetenv("ENGRAM_SETTINGS_PATH")
            try? FileManager.default.removeItem(at: settingsDirectory)
        }

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

        try await client.setSourceEnabled(source: "cline", enabled: true)

        let disabled = try await client.disabledSources()
        XCTAssertEqual(Set(disabled), ["iflow", "lobsterai"])
        XCTAssertFalse(disabled.contains("cline"), "enabling cline must not enable every archived source")
        let persisted = try loadSettings(settingsURL)
        XCTAssertEqual(persisted["customSetting"] as? Bool, true)
        XCTAssertEqual(Set((persisted["disabledSources"] as? [String]) ?? []), ["iflow", "lobsterai"])
        XCTAssertEqual(persisted[ArchivedDefaultOffSources.settingsMigrationKey] as? Bool, true)
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

    /// Full-path alias inputs must normalize to basenames so search project
    /// filters match sessions.project. (repro for B6 path-shape mismatch)
    func testManageProjectAliasNormalizesAbsolutePathsToBasename_repro() async throws {
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
        let addResult = try await client.manageProjectAlias(
            EngramServiceProjectAliasRequest(
                action: "add",
                oldProject: "/Users/bing/-Code-/_maintenance",
                newProject: "/Users/bing/-Code-/-Code-",
                actor: "test"
            )
        )
        let addObject = try XCTUnwrap(addResult.objectValue)
        XCTAssertEqual(addObject["alias"]?.stringValue, "_maintenance")
        XCTAssertEqual(addObject["canonical"]?.stringValue, "-Code-")
        XCTAssertEqual(addObject["changed"]?.intValue, 1)

        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.read { db in
            let aliasCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM project_aliases
                    WHERE alias = '_maintenance' AND canonical = '-Code-'
                """
            )
            XCTAssertEqual(aliasCount, 1)

            let fullPathCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM project_aliases
                    WHERE alias LIKE '/%' OR canonical LIKE '/%'
                """
            )
            XCTAssertEqual(fullPathCount, 0, "aliases must not store absolute paths")
        }

        // remove also accepts path-shaped inputs after normalize
        let removeResult = try await client.manageProjectAlias(
            EngramServiceProjectAliasRequest(
                action: "remove",
                oldProject: "/tmp/_maintenance",
                newProject: "/other/-Code-",
                actor: "test"
            )
        )
        XCTAssertEqual(removeResult.objectValue?["changed"]?.intValue, 1)
        try await queue.read { db in
            let aliasCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM project_aliases
                    WHERE alias = '_maintenance' AND canonical = '-Code-'
                """
            )
            XCTAssertEqual(aliasCount, 0)
        }
    }

    /// Legacy absolute-path alias rows must be rewritten/removed so post-normalize
    /// remove cannot leave ghosts. (repro for P1 residual full-path store)
    func testManageProjectAliasRewritesLegacyFullPathRowsOnTouch_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)

        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO project_aliases (alias, canonical)
                VALUES ('/Users/bing/-Code-/_maintenance', '/Users/bing/-Code-/-Code-')
                """
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
        // Touch via remove with path-shaped inputs; rewrite should collapse then delete.
        let removeResult = try await client.manageProjectAlias(
            EngramServiceProjectAliasRequest(
                action: "remove",
                oldProject: "/Users/bing/-Code-/_maintenance",
                newProject: "/Users/bing/-Code-/-Code-",
                actor: "test"
            )
        )
        XCTAssertEqual(removeResult.objectValue?["alias"]?.stringValue, "_maintenance")
        XCTAssertEqual(removeResult.objectValue?["canonical"]?.stringValue, "-Code-")
        XCTAssertEqual(removeResult.objectValue?["changed"]?.intValue, 1)

        try await queue.read { db in
            let remaining = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_aliases") ?? -1
            XCTAssertEqual(remaining, 0)
            let fullPath = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM project_aliases WHERE alias LIKE '/%' OR canonical LIKE '/%'"
            ) ?? -1
            XCTAssertEqual(fullPath, 0)
        }
    }

    func testSaveInsightSupersedesSameScopeNormalizedMatch() async throws {
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
        let first = try await client.saveInsight(
            EngramServiceSaveInsightRequest(
                content: "Remember the semantic memory backfill gate rule",
                wing: "engram",
                room: "memory",
                importance: 4,
                sourceSessionId: "s1",
                actor: "test",
                type: "procedural"
            )
        )
        let firstId = try XCTUnwrap(first.objectValue?["id"]?.stringValue)
        let second = try await client.saveInsight(
            EngramServiceSaveInsightRequest(
                content: "  remember   the semantic memory backfill gate rule  ",
                wing: "engram",
                room: "memory",
                importance: 5,
                sourceSessionId: "s2",
                actor: "test",
                type: "procedural"
            )
        )
        let secondId = try XCTUnwrap(second.objectValue?["id"]?.stringValue)

        XCTAssertNotEqual(firstId, secondId)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, insight_type, superseded_by
                FROM insights
                WHERE id IN (?, ?)
                ORDER BY id
                """,
                arguments: [firstId, secondId]
            )
            let byId = Dictionary(uniqueKeysWithValues: rows.map { (($0["id"] as String), $0) })
            XCTAssertEqual(byId[firstId]?["superseded_by"] as String?, secondId)
            XCTAssertNil(byId[secondId]?["superseded_by"] as String?)
            XCTAssertEqual(byId[firstId]?["insight_type"] as String?, "procedural")
            XCTAssertEqual(byId[secondId]?["insight_type"] as String?, "procedural")
        }
    }

    func testSaveInsightSupersedesMatchingActiveOutsideFormerTwoHundredRowWindow_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "prepareInsightCapRepro") { writer in
            try writer.migrate()
        }
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO insights (id, content, wing, room, created_at, superseded_by)
                VALUES ('old-clone', 'Remember the uncapped active insight rule', 'engram', 'memory',
                        '2026-01-01T00:00:00Z', NULL)
                """)
            for index in 0..<201 {
                try db.execute(
                    sql: """
                    INSERT INTO insights (id, content, wing, room, created_at, superseded_by)
                    VALUES (?, ?, 'engram', 'memory', ?, NULL)
                    """,
                    arguments: [
                        "unique-\(index)",
                        "Unique active insight number \(index)",
                        String(format: "2026-02-%02dT00:%02d:00Z", (index % 28) + 1, index % 60),
                    ]
                )
            }
        }

        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            readProvider: try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)
        )
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }
        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        )

        let saved = try await client.saveInsight(
            EngramServiceSaveInsightRequest(
                content: "  remember   the uncapped active insight rule  ",
                wing: "engram",
                room: "memory",
                importance: 5,
                sourceSessionId: nil,
                actor: "test"
            )
        )
        let newestId = try XCTUnwrap(saved.objectValue?["id"]?.stringValue)

        try await queue.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = 'old-clone'"),
                newestId
            )
        }
        let matchingActive = try await client.insights().filter {
            $0.content.lowercased().contains("uncapped active insight rule")
        }
        XCTAssertEqual(matchingActive.map(\.id), [newestId])
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

    func testInsightListHidesSupersededRowsAndDeleteRestoresPredecessor_repro() async throws {
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

        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        )
        let content = "Keep the active insight lifecycle visible"
        let first = try await client.saveInsight(
            EngramServiceSaveInsightRequest(
                content: content,
                wing: "engram",
                room: "memory",
                importance: 4,
                sourceSessionId: "s1",
                actor: "test"
            )
        )
        let firstId = try XCTUnwrap(first.objectValue?["id"]?.stringValue)
        let second = try await client.saveInsight(
            EngramServiceSaveInsightRequest(
                content: "  keep   the active insight lifecycle visible  ",
                wing: "engram",
                room: "memory",
                importance: 5,
                sourceSessionId: "s2",
                actor: "test"
            )
        )
        let secondId = try XCTUnwrap(second.objectValue?["id"]?.stringValue)
        let third = try await client.saveInsight(
            EngramServiceSaveInsightRequest(
                content: "KEEP THE ACTIVE INSIGHT LIFECYCLE VISIBLE",
                wing: "engram",
                room: "memory",
                importance: 5,
                sourceSessionId: "s3",
                actor: "test"
            )
        )
        let thirdId = try XCTUnwrap(third.objectValue?["id"]?.stringValue)

        let activeBeforeDelete = try await client.insights()
        XCTAssertEqual(activeBeforeDelete.map(\.id), [thirdId])
        _ = try await client.deleteInsight(EngramServiceDeleteInsightRequest(id: secondId))

        let activeAfterDelete = try await client.insights()
        XCTAssertEqual(activeAfterDelete.map(\.id), [thirdId])
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT superseded_by FROM insights WHERE id = ?",
                    arguments: [firstId]
                ),
                thirdId
            )
        }
    }

    func testDeleteInsightTipKeepsOneNewestInboundPredecessorActive_repro() async throws {
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

        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        )
        var ids: [String] = []
        for source in ["old", "middle", "tip"] {
            let saved = try await client.saveInsight(
                EngramServiceSaveInsightRequest(
                    content: "Collapse duplicate active insight chains",
                    wing: "engram",
                    room: "memory",
                    importance: 5,
                    sourceSessionId: source,
                    actor: "test"
                )
            )
            ids.append(try XCTUnwrap(saved.objectValue?["id"]?.stringValue))
        }
        let oldID = ids[0]
        let middleID = ids[1]
        let tipID = ids[2]
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE insights SET created_at = '2026-08-23T00:00:00Z' WHERE id = ?", arguments: [oldID])
            try db.execute(sql: "UPDATE insights SET created_at = '2026-08-23T00:01:00Z' WHERE id = ?", arguments: [middleID])
            try db.execute(sql: "UPDATE insights SET created_at = '2026-08-23T00:02:00Z' WHERE id = ?", arguments: [tipID])
            try db.execute(
                sql: "UPDATE insights SET superseded_by = ? WHERE id = ?",
                arguments: [tipID, oldID]
            )
        }

        _ = try await client.deleteInsight(.init(id: tipID))

        let activeIDs = try await client.insights().map(\.id)
        XCTAssertEqual(activeIDs, [middleID])
        try await queue.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = ?", arguments: [oldID]),
                middleID
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = ?", arguments: [middleID])
            )
        }
    }

    func testInsightWritesRepairDanglingSameScopeChains_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "prepareDanglingInsightRepro") { writer in
            try writer.migrate()
        }
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO insights (id, content, wing, room, created_at, superseded_by) VALUES
                  ('save-dangling', 'Repair this normalized save chain', 'engram', 'save',
                   '2026-08-23T00:00:00Z', 'missing-save-tip'),
                  ('delete-inbound', 'Repair this normalized delete chain', 'engram', 'delete',
                   '2026-08-23T00:00:00Z', 'delete-bridge'),
                  ('delete-bridge', 'Repair this normalized delete chain', 'engram', 'delete',
                   '2026-08-23T00:01:00Z', 'missing-delete-tip'),
                  ('delete-live-tip', '  REPAIR   this normalized delete chain  ', 'engram', 'delete',
                   '2026-08-23T00:02:00Z', NULL)
                """)
        }

        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            readProvider: try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)
        )
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }
        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        )

        let saved = try await client.saveInsight(
            .init(
                content: "  REPAIR   this normalized save chain  ",
                wing: "engram",
                room: "save",
                importance: 5,
                sourceSessionId: nil,
                actor: "test"
            )
        )
        let savedID = try XCTUnwrap(saved.objectValue?["id"]?.stringValue)
        _ = try await client.deleteInsight(.init(id: "delete-bridge"))

        try await queue.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = 'save-dangling'"),
                savedID
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = 'delete-inbound'"),
                "delete-live-tip"
            )
        }
    }

    func testDeleteInsightRetiresDanglingSameScopeClonesAndReactivatesLivePredecessor_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "prepareInsightDeleteChainRepro") { writer in
            try writer.migrate()
        }
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO insights (id, content, wing, room, created_at, superseded_by) VALUES
                  ('active-old', 'Retire this dangling clone', 'engram', 'delete-a',
                   '2026-08-23T00:00:00Z', NULL),
                  ('dangling-new', '  RETIRE   this dangling clone  ', 'engram', 'delete-a',
                   '2026-08-23T00:01:00Z', 'missing-tip'),
                  ('clone-predecessor', 'Preserve the inbound clone chain', 'engram', 'delete-a',
                   '2026-08-22T23:59:00Z', 'dangling-new'),
                  ('chain-a', 'Repair this deleted middle chain', 'engram', 'delete-b',
                   '2026-08-23T00:00:00Z', 'chain-b'),
                  ('chain-b', 'Repair this deleted middle chain', 'engram', 'delete-b',
                   '2026-08-23T00:01:00Z', 'chain-c'),
                  ('chain-c', 'Repair this deleted middle chain', 'engram', 'delete-b',
                   '2026-08-23T00:02:00Z', 'missing-chain-tip');
                """)
        }
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            readProvider: try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)
        )
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }
        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        )

        _ = try await client.deleteInsight(.init(id: "active-old"))
        _ = try await client.deleteInsight(.init(id: "chain-b"))

        try await queue.read { db in
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT id FROM insights WHERE id IN ('active-old', 'dangling-new') ORDER BY id"
                ),
                []
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = 'clone-predecessor'"),
                "deleting a dangling clone must splice its inbound pointers instead of leaving a deleted target"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT superseded_by FROM insights WHERE id = 'chain-a'")
            )
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT id FROM insights WHERE id = 'chain-c'"))
        }
    }

    func testFormerBridgeCommandsUseNativeServiceBehavior() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let home = paths.runtime.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let settingsDirectory = home.appendingPathComponent(".engram", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        try #"{"titleProvider":"native"}"#.write(
            to: settingsDirectory.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )
        let homeScope = ServiceCoreTestHomeScope(home: home)
        defer { homeScope.restore() }

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

        // Native hygiene runs a real read-only scan over the fixture (no longer
        // the fail-closed bridge stub). s2 carries a suggested_parent_id with a
        // NULL parent → exactly one pending-suggestions issue, so score = 99.
        let hygiene = try await client.hygiene(force: false)
        XCTAssertEqual(hygiene.score, 99)
        let hygieneIssue = try XCTUnwrap(hygiene.issues.first)
        XCTAssertEqual(hygieneIssue.kind, "pending-suggestions")
        XCTAssertEqual(hygieneIssue.severity, "info")
        XCTAssertFalse(hygiene.checkedAt.isEmpty)

        let handoff = try await client.handoff(
            EngramServiceHandoffRequest(cwd: "/tmp/engram", sessionId: nil, format: "markdown")
        )
        XCTAssertEqual(handoff.sessionCount, 1)
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

        let titleQueue = try DatabaseQueue(path: paths.database.path)
        try await titleQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET generated_title = NULL")
        }
        let titles = try await client.regenerateAllTitles()
        XCTAssertTrue(["started", "running"].contains(titles.status))
        XCTAssertNil(titles.total)

        let titleDeadline = Date().addingTimeInterval(5)
        while Date() < titleDeadline {
            let missingTitles = try await titleQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sessions WHERE generated_title IS NULL"
                ) ?? 0
            }
            if missingTitles == 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let missingTitles = try await titleQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sessions WHERE generated_title IS NULL"
            ) ?? 0
        }
        XCTAssertEqual(missingTitles, 0, "title regeneration should finish before the scoped HOME is restored")
    }

    func testHandoffListingFiltersHiddenSkipAndChildSessionsButByIDRemainsUnfiltered_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (
                  id, source, start_time, cwd, project, message_count, file_path,
                  size_bytes, indexed_at, tier, hidden_at, parent_session_id
                ) VALUES
                  ('skip-child', 'codex', '2026-04-23T03:00:00Z', '/tmp/engram', 'engram', 1,
                   '/tmp/skip-child.jsonl', 10, '2026-04-23T03:00:00Z', 'skip', NULL, 's1'),
                  ('normal-child', 'codex', '2026-04-23T04:00:00Z', '/tmp/engram', 'engram', 1,
                   '/tmp/normal-child.jsonl', 10, '2026-04-23T04:00:00Z', 'normal', NULL, 's1'),
                  ('hidden-top', 'codex', '2026-04-23T05:00:00Z', '/tmp/engram', 'engram', 1,
                   '/tmp/hidden-top.jsonl', 10, '2026-04-23T05:00:00Z', 'normal', datetime('now'), NULL)
                """)
        }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }
        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        )

        let listing = try await client.handoff(
            EngramServiceHandoffRequest(cwd: "/tmp/engram", sessionId: nil, format: "markdown")
        )
        XCTAssertEqual(listing.sessionCount, 1)
        XCTAssertFalse(listing.brief.contains("skip-child"))
        XCTAssertFalse(listing.brief.contains("normal-child"))
        XCTAssertFalse(listing.brief.contains("hidden-top"))

        let explicitSkip = try await client.handoff(
            EngramServiceHandoffRequest(cwd: "/tmp/engram", sessionId: "skip-child", format: "plain")
        )
        XCTAssertEqual(explicitSkip.sessionCount, 1, "explicit by-id handoff must remain unfiltered")
    }

    func testGenerateSummaryRejectsSkipAndEmptyTranscriptWithoutPersistingMetadata_repro() async throws {
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let home = paths.runtime.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let homeScope = ServiceCoreTestHomeScope(home: home)
        defer { homeScope.restore() }

        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(sql: """
                UPDATE sessions SET tier = 'skip' WHERE id = 's1';
                UPDATE sessions SET generated_title = 'Metadata only', summary = NULL WHERE id = 's2';
                DELETE FROM sessions_fts WHERE session_id = 's2';
                """)
        }

        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }
        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        )

        for sessionID in ["s1", "s2"] {
            do {
                _ = try await client.generateSummary(
                    EngramServiceGenerateSummaryRequest(sessionId: sessionID)
                )
                XCTFail("generateSummary must reject non-summarizable session \(sessionID)")
            } catch let error as EngramServiceError {
                guard case .invalidRequest = error else {
                    return XCTFail("expected invalidRequest for \(sessionID), got \(error)")
                }
            }
        }

        try await queue.read { db in
            for sessionID in ["s1", "s2"] {
                let row = try XCTUnwrap(Row.fetchOne(
                    db,
                    sql: "SELECT summary, summary_message_count FROM sessions WHERE id = ?",
                    arguments: [sessionID]
                ))
                XCTAssertNil(row["summary"] as String?)
                XCTAssertNil(row["summary_message_count"] as Int?)
            }
        }
    }

    func testServiceAIClientTransportErrorsPreserveStructuredEnvelopeFields() async throws {
        let config = EngramServiceCommandHandler.ServiceAISettings.ChatConfig(
            provider: "openai",
            baseURL: "http://127.0.0.1:1",
            apiKey: "test",
            model: "gpt-test",
            maxTokens: 16,
            temperature: 0
        )

        do {
            _ = try await EngramServiceCommandHandler.ServiceAIClient.chat(
                purpose: "summary",
                sessionID: "s1",
                config: config,
                messages: [["role": "user", "content": "hello"]]
            )
            XCTFail("Expected URLSession transport failure to be converted into EngramServiceError")
        } catch let error as EngramServiceError {
            guard case .commandFailed(let name, let message, let retryPolicy, let details) = error else {
                return XCTFail("Expected commandFailed, got \(error)")
            }
            XCTAssertEqual(name, "AIRequestTransportFailed")
            XCTAssertEqual(retryPolicy, "safe")
            XCTAssertTrue(message.contains("AI request transport failed"), message)
            XCTAssertEqual(details?["provider"], .string("openai"))
            XCTAssertEqual(details?["model"], .string("gpt-test"))
            XCTAssertEqual(details?["url"], .string("http://127.0.0.1"))
        } catch {
            XCTFail("Expected EngramServiceError, got \(error)")
        }
    }

    func testGenerateProjectWorkTitlesWithoutAIConfigReturnsEmptyTitles() async throws {
        // With no title AI config in the test home, the on-demand command must be
        // a no-op: it returns a response (empty titles) so the app keeps its
        // heuristic title, and it must be authorized (not UnsupportedCommand).
        let paths = try makeServiceIPCPaths()
        try seedSearchFixture(at: paths.database.path)
        let home = paths.runtime.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let homeScope = ServiceCoreTestHomeScope(home: home)
        defer { homeScope.restore() }

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

        let response = try await client.generateProjectWorkTitles(
            EngramServiceGenerateProjectWorkTitlesRequest(project: "engram")
        )
        XCTAssertTrue(response.titles.isEmpty)
    }

    // MARK: - generateProjectWorkTitles caching / no-op (via injected AI seam)

    private actor WorkTitleCallCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private actor WorkTitlePromptCapture {
        private(set) var value = (intent: "", outcome: "")
        func record(intent: String, outcome: String) { value = (intent, outcome) }
    }

    private static let fakeTitleConfig = EngramServiceCommandHandler.ServiceAISettings.ChatConfig(
        provider: "custom", baseURL: "http://localhost", apiKey: "",
        model: "test-model", maxTokens: 120, temperature: 0.3
    )

    /// Migrated DB with one human-driven session and two work items (wk-a, wk-b)
    /// under project "p". Source 'cursor' + NULL instruction_count passes the
    /// human-driven filter that `readProjectWorkItems` applies.
    private func makeWorkTitleGate() async throws -> ServiceWriterGate {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            queueTimeoutNanoseconds: 20_000_000
        )
        _ = try await gate.performWriteCommand(name: "seedWorkBeats") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (id, source, start_time, file_path, project, tier)
                    VALUES ('p1', 'cursor', '2026-06-25T10:00:00Z', '/tmp/p1.jsonl', 'p', 'normal')
                    """)
                try db.execute(sql: """
                    INSERT INTO session_work_beats
                        (session_id, beat_index, action_date, action_timestamp, work_key,
                         work_title, human_intent, assistant_outcome, kind, status,
                         operation_events, confidence)
                    VALUES
                        ('p1', 0, date('now', 'localtime'), datetime('now'), 'wk-a',
                         'A', 'intent A', 'outcome A', 'implementation', 'completed', '[]', 0.9),
                        ('p1', 1, date('now', 'localtime'), datetime('now'), 'wk-b',
                         'B', 'intent B', 'outcome B', 'fix', 'completed', '[]', 0.9)
                    """)
            }
        }
        return gate
    }

    private func workItemTitleCount(gate: ServiceWriterGate, project: String) async throws -> Int {
        try await gate.performWriteCommand(name: "readTitles") { writer in
            try writer.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM work_item_titles WHERE project = ?",
                    arguments: [project]
                ) ?? 0
            }
        }.value
    }

    func testReadProjectWorkItemsUsesSQLiteLocalDayCutoff_repro() async throws {
        let originalTZ = ProcessInfo.processInfo.environment["TZ"]
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcHour = utcCalendar.component(.hour, from: Date())
        setenv("TZ", utcHour < 12 ? "Etc/GMT+12" : "Pacific/Kiritimati", 1)
        tzset()
        defer {
            if let originalTZ { setenv("TZ", originalTZ, 1) } else { unsetenv("TZ") }
            tzset()
        }

        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "seedLocalWorkBeat") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (id, source, start_time, file_path, project, tier)
                    VALUES ('local-day', 'cursor', datetime('now'), '/tmp/local-day.jsonl', 'p', 'normal');
                    INSERT INTO session_work_beats
                        (session_id, beat_index, action_date, action_timestamp, work_key,
                         work_title, human_intent, assistant_outcome, kind, status,
                         operation_events, confidence)
                    VALUES
                        ('local-day', 0, date('now', 'localtime'), datetime('now'), 'local-work',
                         'Local work', 'intent', 'outcome', 'implementation', 'completed', '[]', 0.9),
                        ('local-day', 1, 'unknown', NULL, 'unknown-work',
                         'Unknown work', 'intent', 'outcome', 'implementation', 'completed', '[]', 0.9);
                    """)
            }
        }

        // docs/invariants.md #6: the database and runtime paths are both temporary.
        let items = try EngramServiceCommandHandler.readProjectWorkItems(
            project: "p",
            days: 0,
            databasePath: paths.database.path
        )

        XCTAssertEqual(items.map(\.workKey), ["local-work"])
    }

    func testReadProjectWorkItemsPromotesSuggestedChildWhenHostIsNotHumanDriven_repro() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "seedPromotedWorkBeat") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (
                      id, source, start_time, file_path, project, tier,
                      instruction_count, human_turn_count, user_message_count,
                      suggested_parent_id
                    ) VALUES
                      ('weak-work-host', 'claude-code', datetime('now'), '/tmp/weak-host.jsonl',
                       'p', 'normal', 1, 1, 1, NULL),
                      ('promoted-work-child', 'cursor', datetime('now'), '/tmp/promoted-child.jsonl',
                       'p', 'normal', NULL, NULL, 2, 'weak-work-host');
                    INSERT INTO session_work_beats
                        (session_id, beat_index, action_date, action_timestamp, work_key,
                         work_title, human_intent, assistant_outcome, kind, status,
                         operation_events, confidence)
                    VALUES
                      ('promoted-work-child', 0, date('now', 'localtime'), datetime('now'),
                       'promoted-work', 'Promoted', 'human request', 'completed',
                       'implementation', 'completed', '[]', 0.9);
                    """)
            }
        }

        let items = try EngramServiceCommandHandler.readProjectWorkItems(
            project: "p",
            days: 1,
            databasePath: paths.database.path
        )

        XCTAssertEqual(items.map(\.workKey), ["promoted-work"])
    }

    func testGenerateProjectWorkTitlesPromptsFromNewestWindowButHashesAllDisplayedKeyBeats_repro() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        _ = try await gate.performWriteCommand(name: "seedWindowedWorkBeats") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (id, source, start_time, file_path, project, tier)
                    VALUES
                      ('old', 'cursor', '2025-01-01T10:00:00Z', '/tmp/old.jsonl', 'p', 'normal'),
                      ('new', 'cursor', '2026-01-15T10:00:00Z', '/tmp/new.jsonl', 'p', 'normal');
                    INSERT INTO session_work_beats
                        (session_id, beat_index, action_date, action_timestamp, work_key,
                         work_title, human_intent, assistant_outcome, kind, status,
                         operation_events, confidence)
                    VALUES
                      ('old', 0, '2025-01-01', '2025-01-01T10:00:00Z', 'shared',
                       'Shared', 'old intent outside window', 'old outcome outside window', 'implementation', 'completed', '[]', 0.9),
                      ('new', 0, '2026-01-15', '2026-01-15T10:00:00Z', 'shared',
                       'Shared', 'new intent', 'new outcome', 'implementation', 'completed', '[]', 0.9);
                    """)
            }
        }

        let captured = WorkTitlePromptCapture()
        _ = try await EngramServiceCommandHandler.generateProjectWorkTitles(
            EngramServiceGenerateProjectWorkTitlesRequest(
                project: "p",
                now: ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")
            ),
            writerGate: gate,
            titleConfig: Self.fakeTitleConfig
        ) { intent, outcome, _ in
            await captured.record(intent: intent, outcome: outcome)
            return "Stable title"
        }

        let prompt = await captured.value
        XCTAssertTrue(prompt.intent.contains("new intent"))
        XCTAssertTrue(prompt.outcome.contains("new outcome"))
        XCTAssertFalse(prompt.intent.contains("old intent outside window"))
        XCTAssertFalse(prompt.outcome.contains("old outcome outside window"))

        _ = try await gate.performWriteCommand(name: "mutateOldDisplayedKeyBeat") { writer in
            try writer.write { db in
                try db.execute(
                    sql: "UPDATE session_work_beats SET human_intent = 'changed old intent outside window' WHERE session_id = 'old'"
                )
            }
        }
        let counter = WorkTitleCallCounter()
        _ = try await EngramServiceCommandHandler.generateProjectWorkTitles(
            EngramServiceGenerateProjectWorkTitlesRequest(
                project: "p",
                now: ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")
            ),
            writerGate: gate,
            titleConfig: Self.fakeTitleConfig
        ) { _, _, _ in
            await counter.increment()
            return "Regenerated title"
        }
        let regeneratedCount = await counter.value
        XCTAssertEqual(regeneratedCount, 1, "all beats of a displayed key must participate in the cache hash")
    }

    func testGenerateProjectWorkTitlesSkipsCachedAndRegeneratesOnChange() async throws {
        let gate = try await makeWorkTitleGate()
        let counter = WorkTitleCallCounter()
        let gen: @Sendable (String, String, EngramServiceCommandHandler.ServiceAISettings.ChatConfig) async throws -> String = { intent, _, _ in
            await counter.increment()
            return "T:\(intent)"
        }
        let req = EngramServiceGenerateProjectWorkTitlesRequest(project: "p")

        // Call 1: both work items missing -> 2 generations, 2 rows persisted.
        _ = try await EngramServiceCommandHandler.generateProjectWorkTitles(
            req, writerGate: gate, titleConfig: Self.fakeTitleConfig, generateTitle: gen
        )
        let afterFirst = await counter.value
        XCTAssertEqual(afterFirst, 2)
        let rowsAfterFirst = try await workItemTitleCount(gate: gate, project: "p")
        XCTAssertEqual(rowsAfterFirst, 2)

        // Call 2: unchanged content -> intent_hash matches -> no new generation.
        _ = try await EngramServiceCommandHandler.generateProjectWorkTitles(
            req, writerGate: gate, titleConfig: Self.fakeTitleConfig, generateTitle: gen
        )
        let afterSecond = await counter.value
        XCTAssertEqual(afterSecond, 2, "cached titles must not be regenerated")

        // Mutate wk-a's outcome -> its intent_hash changes.
        _ = try await gate.performWriteCommand(name: "mutate") { writer in
            try writer.write { db in
                try db.execute(sql: "UPDATE session_work_beats SET assistant_outcome = 'outcome A v2' WHERE work_key = 'wk-a'")
            }
        }
        // Call 3: only wk-a is stale -> exactly one more generation.
        _ = try await EngramServiceCommandHandler.generateProjectWorkTitles(
            req, writerGate: gate, titleConfig: Self.fakeTitleConfig, generateTitle: gen
        )
        let afterThird = await counter.value
        XCTAssertEqual(afterThird, 3, "only the changed work item must regenerate")
    }

    func testGenerateProjectWorkTitlesNoAIConfigPersistsNothingWithWorkItems() async throws {
        let gate = try await makeWorkTitleGate()
        let gen: @Sendable (String, String, EngramServiceCommandHandler.ServiceAISettings.ChatConfig) async throws -> String = { _, _, _ in
            XCTFail("generateTitle must not be called when titleConfig is nil")
            return ""
        }
        let result = try await EngramServiceCommandHandler.generateProjectWorkTitles(
            EngramServiceGenerateProjectWorkTitlesRequest(project: "p"),
            writerGate: gate, titleConfig: nil, generateTitle: gen
        )
        XCTAssertTrue(result.value.titles.isEmpty, "no-config path returns no titles")
        let rows = try await workItemTitleCount(gate: gate, project: "p")
        XCTAssertEqual(rows, 0, "no-config path must not persist heuristic titles")
    }

    func testGenerateProjectWorkTitlesSkipsEmptyTitlesSoTheyCanRetry() async throws {
        let gate = try await makeWorkTitleGate()
        let counter = WorkTitleCallCounter()
        let emptyGen: @Sendable (String, String, EngramServiceCommandHandler.ServiceAISettings.ChatConfig) async throws -> String = { _, _, _ in
            await counter.increment()
            return ""
        }
        let req = EngramServiceGenerateProjectWorkTitlesRequest(project: "p")

        _ = try await EngramServiceCommandHandler.generateProjectWorkTitles(
            req, writerGate: gate, titleConfig: Self.fakeTitleConfig, generateTitle: emptyGen
        )
        let afterEmpty = await counter.value
        XCTAssertEqual(afterEmpty, 2)
        var rows = try await workItemTitleCount(gate: gate, project: "p")
        XCTAssertEqual(rows, 0, "empty generated titles must not be persisted as cache hits")

        let recoveredGen: @Sendable (String, String, EngramServiceCommandHandler.ServiceAISettings.ChatConfig) async throws -> String = { intent, _, _ in
            await counter.increment()
            return "Recovered \(intent)"
        }
        _ = try await EngramServiceCommandHandler.generateProjectWorkTitles(
            req, writerGate: gate, titleConfig: Self.fakeTitleConfig, generateTitle: recoveredGen
        )
        let afterRecovery = await counter.value
        XCTAssertEqual(afterRecovery, 4, "work items with empty title attempts must be retried")
        rows = try await workItemTitleCount(gate: gate, project: "p")
        XCTAssertEqual(rows, 2)
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
        let missingSrc = home.appendingPathComponent(".engram-test-missing-src-\(UUID().uuidString)")
        let missingDst = home.appendingPathComponent(".engram-test-missing-dst-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: missingSrc) }
        defer { try? FileManager.default.removeItem(at: missingDst) }
        do {
            _ = try await client.projectMove(
                EngramServiceProjectMoveRequest(
                    src: missingSrc.path,
                    dst: missingDst.path,
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

    func testRunnerInsightEmbeddingBackfillEmbedsOutsideWriteGate() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            queueTimeoutNanoseconds: 20_000_000
        )
        _ = try await gate.performWriteCommand(name: "seedInsight") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(
                    sql: "INSERT INTO insights (id, content, importance) VALUES ('probe-insight', 'gate probe insight', 5)"
                )
            }
        }
        let probe = EmbeddingGateProbe()

        let embedded = try await EngramServiceRunner.backfillInsightEmbeddingsOnce(
            gate: gate,
            environment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
            ],
            providerFactory: { _ in GateProbingEmbeddingProvider(gate: gate, probe: probe) },
            limit: 8
        )

        XCTAssertEqual(embedded, 1)
        let providerWriteSucceeded = await probe.writeSucceeded()
        XCTAssertTrue(providerWriteSucceeded)
        let counts = try await gate.performWriteCommand(name: "assertInsightEmbedding") { writer in
            try writer.read { db -> (Int, Int, Int) in
                let embeddings = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insight_embeddings") ?? 0
                let probes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embedding_gate_probe") ?? 0
                let hasEmbedding = try Int.fetchOne(
                    db,
                    sql: "SELECT has_embedding FROM insights WHERE id = 'probe-insight'"
                ) ?? 0
                return (embeddings, probes, hasEmbedding)
            }
        }.value
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 1, "EMB-009: a successful insight write must set has_embedding")
    }

    // R4-dual-tx: shipped runner success vectors and item-failure accounting
    // must share one SQLite transaction, not merely one ServiceWriterGate phase.
    func testRunnerInsightEmbeddingRollsBackSuccessWhenFailureAccountingThrows_repro() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            queueTimeoutNanoseconds: 20_000_000
        )
        _ = try await gate.performWriteCommand(name: "seedAtomicInsightBatch") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO insights (id, content, importance) VALUES
                      ('atomic-good', 'good insight content long enough for embed', 5),
                      ('atomic-poison', 'BAD poison insight content long enough', 5)
                    """)
                try db.execute(sql: """
                    CREATE TRIGGER force_insight_failure_accounting_error
                    BEFORE INSERT ON insight_embedding_failures
                    BEGIN
                      SELECT RAISE(ABORT, 'forced failure accounting error');
                    END
                    """)
            }
        }

        do {
            _ = try await EngramServiceRunner.backfillInsightEmbeddingsOnce(
                gate: gate,
                environment: [
                    "ENGRAM_EMBEDDING_API_KEY": "test",
                    "ENGRAM_EMBEDDING_MODEL": "selective-model",
                    "ENGRAM_EMBEDDING_DIM": "3",
                ],
                providerFactory: { _ in SelectiveFailInsightEmbeddingProvider() },
                backoff: EmbeddingMaintenanceBackoff(),
                limit: 10
            )
            XCTFail("expected forced failure-accounting error")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("forced failure accounting error"),
                "unexpected error: \(error)"
            )
        }

        let state = try await gate.performWriteCommand(name: "assertAtomicInsightRollback") { writer in
            try writer.read { db -> (Int, Int, Int) in
                let embeddings = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM insight_embeddings WHERE insight_id = 'atomic-good'"
                ) ?? 0
                let failures = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM insight_embedding_failures WHERE insight_id = 'atomic-poison'"
                ) ?? 0
                let hasEmbedding = try Int.fetchOne(
                    db,
                    sql: "SELECT has_embedding FROM insights WHERE id = 'atomic-good'"
                ) ?? 0
                return (embeddings, failures, hasEmbedding)
            }
        }.value
        XCTAssertEqual(state.0, 0, "success vector must roll back with failed item accounting")
        XCTAssertEqual(state.1, 0, "forced failure accounting insert must not commit")
        XCTAssertEqual(state.2, 0, "has_embedding must roll back with the success vector")
    }

    // PR #197: shipped runner isolates explicit item-local rejection and terminalizes it.
    /// `backfillInsightEmbeddingsOnce` (not the helper-only
    /// `InsightEmbeddingBackfill.run`) must isolate poison insights and
    /// terminalize them so they stop being reselected.
    func testRunnerInsightEmbeddingIsolatesPoisonAndTerminates_repro() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            queueTimeoutNanoseconds: 20_000_000
        )
        _ = try await gate.performWriteCommand(name: "seedPoisonInsight") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO insights (id, content, importance) VALUES
                      ('good', 'good insight content long enough for embed', 5),
                      ('poison', 'BAD poison insight content long enough', 5)
                    """)
            }
        }

        let clock = InsightBackoffClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let backoff = EmbeddingMaintenanceBackoff(
            baseDelay: 1,
            maximumDelay: 1,
            now: { clock.now }
        )
        let env = [
            "ENGRAM_EMBEDDING_API_KEY": "test",
            "ENGRAM_EMBEDDING_MODEL": "selective-model",
            "ENGRAM_EMBEDDING_DIM": "3",
        ]
        let providerFactory: @Sendable (EmbeddingConfig) -> any EmbeddingProvider = { _ in
            SelectiveFailInsightEmbeddingProvider()
        }

        let first = try await EngramServiceRunner.backfillInsightEmbeddingsOnce(
            gate: gate,
            environment: env,
            providerFactory: providerFactory,
            backoff: backoff,
            limit: 10
        )
        XCTAssertEqual(first, 1, "R4 product: good insight must still embed")

        let afterFirst = try await gate.performWriteCommand(name: "assertFirstIsolation") { writer in
            try writer.read { db -> (Int, Int, String?) in
                let good = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM insight_embeddings WHERE insight_id = 'good'"
                ) ?? 0
                let poisonEmb = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM insight_embeddings WHERE insight_id = 'poison'"
                ) ?? 0
                let status = try String.fetchOne(
                    db,
                    sql: "SELECT status FROM insight_embedding_failures WHERE insight_id = 'poison'"
                )
                return (good, poisonEmb, status)
            }
        }.value
        XCTAssertEqual(afterFirst.0, 1)
        XCTAssertEqual(afterFirst.1, 0)
        XCTAssertEqual(afterFirst.2, "failed_retryable")

        // Exhaust retries on the shipped path; advance backoff between runs.
        for _ in 0..<InsightEmbeddingBackfill.maxInsightEmbedRetryCount {
            clock.advance(by: 2)
            _ = try await EngramServiceRunner.backfillInsightEmbeddingsOnce(
                gate: gate,
                environment: env,
                providerFactory: providerFactory,
                backoff: backoff,
                limit: 10
            )
        }

        let terminal = try await gate.performWriteCommand(name: "assertPoisonTerminal") { writer in
            try writer.read { db -> (String?, [String]) in
                let status = try String.fetchOne(
                    db,
                    sql: "SELECT status FROM insight_embedding_failures WHERE insight_id = 'poison'"
                )
                // Inline pending SQL (same as pendingInsights) — cannot nest
                // writer.read via pendingInsights while already in a gate write.
                let pending = try String.fetchAll(
                    db,
                    sql: """
                    SELECT i.id AS id
                    FROM insights i
                    LEFT JOIN insight_embeddings e ON e.insight_id = i.id
                    LEFT JOIN insight_embedding_failures f ON f.insight_id = i.id
                    WHERE e.insight_id IS NULL
                      AND (f.insight_id IS NULL OR f.status != 'failed_permanent')
                    ORDER BY i.created_at DESC
                    LIMIT 10
                    """
                )
                return (status, pending)
            }
        }.value
        XCTAssertEqual(
            terminal.0,
            "failed_permanent",
            "R4 product: permanent after retry budget on backfillInsightEmbeddingsOnce"
        )
        XCTAssertFalse(
            terminal.1.contains("poison"),
            "R4 product: permanent poison must not reselect forever"
        )
        XCTAssertFalse(terminal.1.contains("good"))
    }

    // PR #197 follow-up: provider/config dimension mismatch remains retryable on the shipped runner.
    func testRunnerInsightDimensionMismatchDoesNotTerminalize_repro() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            queueTimeoutNanoseconds: 20_000_000
        )
        _ = try await gate.performWriteCommand(name: "seedDimensionInsight") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(
                    sql: "INSERT INTO insights (id, content, importance) VALUES ('dimension', 'dimension mismatch insight content', 5)"
                )
            }
        }

        let clock = InsightBackoffClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let backoff = EmbeddingMaintenanceBackoff(
            baseDelay: 1,
            maximumDelay: 1,
            now: { clock.now }
        )
        let env = [
            "ENGRAM_EMBEDDING_API_KEY": "test",
            "ENGRAM_EMBEDDING_MODEL": "probe",
            "ENGRAM_EMBEDDING_DIM": "3",
        ]

        for _ in 0..<InsightEmbeddingBackfill.maxInsightEmbedRetryCount {
            do {
                _ = try await EngramServiceRunner.backfillInsightEmbeddingsOnce(
                    gate: gate,
                    environment: env,
                    providerFactory: { _ in WrongDimensionInsightEmbeddingProvider() },
                    backoff: backoff,
                    limit: 10
                )
                XCTFail("expected dimension mismatch")
            } catch let error as EmbeddingError {
                XCTAssertEqual(error, .dimensionMismatch(expected: 3, actual: 2))
            }
            clock.advance(by: 2)
        }

        let failureCount = try await gate.performWriteCommand(name: "assertDimensionRetryable") { writer in
            try writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insight_embedding_failures") ?? 0
            }
        }.value
        XCTAssertEqual(failureCount, 0)

        let recovered = try await EngramServiceRunner.backfillInsightEmbeddingsOnce(
            gate: gate,
            environment: env,
            providerFactory: { _ in StaticEmbeddingProvider { _ in [1, 0, 0] } },
            backoff: backoff,
            limit: 10
        )
        XCTAssertEqual(recovered, 1)
    }

    func testRunnerSessionEmbeddingBackfillEmbedsOutsideWriteGate() async throws {
        let paths = try makeServiceIPCPaths()
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            queueTimeoutNanoseconds: 20_000_000
        )
        _ = try await gate.performWriteCommand(name: "seedSessionEmbeddingJob") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (id, source, start_time, file_path, tier)
                    VALUES ('semantic-session', 'codex', '2026-06-26T10:00:00Z', '/tmp/semantic.jsonl', 'normal')
                    """)
                try db.execute(
                    sql: """
                    INSERT INTO sessions_fts(session_id, content)
                    VALUES ('semantic-session', 'memory search chunk')
                    """
                )
                try db.execute(
                    sql: """
                    INSERT INTO session_index_jobs (id, session_id, job_kind, target_sync_version, status)
                    VALUES ('semantic-session:1:h:embedding', 'semantic-session', 'embedding', 1, 'pending')
                    """
                )
            }
        }
        let probe = EmbeddingGateProbe()

        let completed = try await EngramServiceRunner.backfillSessionEmbeddingsOnce(
            gate: gate,
            environment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
            ],
            providerFactory: { _ in GateProbingEmbeddingProvider(gate: gate, probe: probe) },
            limit: 8
        )

        XCTAssertEqual(completed, 1)
        let providerWriteSucceeded = await probe.writeSucceeded()
        XCTAssertTrue(providerWriteSucceeded)
        let result = try await gate.performWriteCommand(name: "assertSessionEmbedding") { writer in
            try writer.read { db -> (Int, String?) in
                let chunks = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM semantic_chunks WHERE session_id = 'semantic-session'"
                ) ?? 0
                let status = try String.fetchOne(
                    db,
                    sql: "SELECT status FROM session_index_jobs WHERE id = 'semantic-session:1:h:embedding'"
                )
                return (chunks, status)
            }
        }.value
        XCTAssertEqual(result.0, 1)
        XCTAssertEqual(result.1, "completed")
    }

}

private actor EmbeddingGateProbe {
    private var succeeded = false

    func writeSucceeded() -> Bool { succeeded }

    func markSucceeded() {
        succeeded = true
    }
}

private struct GateProbingEmbeddingProvider: EmbeddingProvider {
    let model = "probe"
    let dimension = 3
    let gate: ServiceWriterGate
    let probe: EmbeddingGateProbe

    func embed(_ texts: [String]) async throws -> [[Float]] {
        _ = try await gate.performWriteCommand(name: "embeddingProviderGateProbe") { writer in
            try writer.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS embedding_gate_probe(id INTEGER PRIMARY KEY)")
                try db.execute(sql: "INSERT INTO embedding_gate_probe DEFAULT VALUES")
            }
        }
        await probe.markSucceeded()
        return texts.map { text in VectorMath.l2Normalize([Float(text.count), 1, 0]) }
    }
}

private struct StaticEmbeddingProvider: EmbeddingProvider {
    let model = "probe"
    let dimension = 3
    let vector: @Sendable (String) -> [Float]

    init(_ vector: @escaping @Sendable (String) -> [Float]) {
        self.vector = vector
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { VectorMath.l2Normalize(vector($0)) }
    }
}

/// R4: explicit item-local rejection for content containing "BAD".
private struct SelectiveFailInsightEmbeddingProvider: EmbeddingProvider {
    let model = "selective-model"
    let dimension = 3
    func embed(_ texts: [String]) async throws -> [[Float]] {
        if texts.contains(where: { $0.contains("BAD") }) {
            throw EmbeddingError.inputRejected("content rejected")
        }
        return texts.map { _ in [1, 0, 0] }
    }
}

private struct WrongDimensionInsightEmbeddingProvider: EmbeddingProvider {
    let model = "probe"
    let dimension = 3
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1, 0] }
    }
}

private final class InsightBackoffClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(start: Date) { _now = start }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(seconds)
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

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
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

private func makePrivateSettingsFixture() throws -> (directory: URL, settingsURL: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-settings-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return (directory, directory.appendingPathComponent("settings.json"))
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

private func waitUntilServerDrainsClientTasks(
    _ server: UnixSocketServiceServer,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let deadline = Date().addingTimeInterval(5)
    while server.activeClientTaskCountForTesting() != 0 {
        if Date() >= deadline {
            XCTFail("timed out waiting for server client tasks to drain", file: file, line: line)
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
              last_accessed_at TEXT,
              access_count INTEGER NOT NULL DEFAULT 0,
              generated_title TEXT,
              parent_session_id TEXT,
              suggested_parent_id TEXT,
              suggestion_status TEXT,
              suggestion_candidates TEXT,
              link_source TEXT,
              link_checked_at TEXT,
              orphan_status TEXT,
              has_embedding INTEGER NOT NULL DEFAULT 0,
              offload_state TEXT NOT NULL DEFAULT 'local'
            );
            CREATE TABLE session_local_state (
              session_id TEXT PRIMARY KEY,
              hidden_at TEXT,
              custom_name TEXT,
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

private func seedSemanticSearchFixture(at path: String) throws {
    try seedSearchFixture(at: path)
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(sql: """
            CREATE TABLE semantic_chunks (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              chunk_index INTEGER NOT NULL,
              text TEXT NOT NULL,
              embedding BLOB,
              model TEXT,
              dim INTEGER,
              created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE TABLE embedding_meta (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              provider TEXT,
              model TEXT,
              dimension INTEGER,
              updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            INSERT INTO embedding_meta (id, provider, model, dimension)
            VALUES (1, 'test', 'probe', 3);
            """)
        try db.execute(
            sql: """
                INSERT INTO semantic_chunks(id, session_id, chunk_index, text, embedding, model, dim)
                VALUES ('s2:c0', 's2', 0, 'semantic recall chunk', ?, 'probe', 3)
                """,
            arguments: [VectorMath.encode(VectorMath.l2Normalize([1, 0, 0]))]
        )
    }
}

private func seedOriginFilteredSemanticSearchFixture(
    at path: String,
    targetOrigin: String,
    interferenceOrigin: String,
    interferenceCount: Int
) throws {
    try seedSemanticSearchFixture(at: path)
    let queue = try DatabaseQueue(path: path)
    let targetEmbedding = VectorMath.encode(VectorMath.l2Normalize([0.1, 1, 0]))
    let interferenceEmbedding = VectorMath.encode(VectorMath.l2Normalize([1, 0, 0]))
    try queue.write { db in
        try db.execute(
            sql: "UPDATE sessions SET origin = ? WHERE id = 's2'",
            arguments: [targetOrigin]
        )
        try db.execute(
            sql: "DELETE FROM semantic_chunks WHERE id = 's2:c0'"
        )
        try db.execute(
            sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('s2', 'originneedle target')"
        )

        for index in 0 ..< interferenceCount {
            let id = "reverse-origin-\(index)"
            try db.execute(
                sql: """
                    INSERT INTO sessions (
                      id, source, start_time, cwd, project, message_count,
                      file_path, size_bytes, indexed_at, tier, origin
                    ) VALUES (?, 'codex', '2026-08-30T12:00:00Z', '/tmp/reverse',
                              'engram', 2, ?, 42, '2026-08-30T12:30:00Z', 'normal', ?)
                    """,
                arguments: [id, "/tmp/\(id).jsonl", interferenceOrigin]
            )
            try db.execute(
                sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, 'originneedle interference')",
                arguments: [id]
            )
            try db.execute(
                sql: """
                    INSERT INTO semantic_chunks(
                      id, session_id, chunk_index, text, embedding, model, dim
                    ) VALUES (?, ?, 0, 'originneedle interference', ?, 'probe', 3)
                    """,
                arguments: ["\(id):c0", id, interferenceEmbedding]
            )
        }
        try db.execute(
            sql: """
                INSERT INTO semantic_chunks(
                  id, session_id, chunk_index, text, embedding, model, dim
                ) VALUES ('s2:c0', 's2', 0, 'originneedle target', ?, 'probe', 3)
                """,
            arguments: [targetEmbedding]
        )
    }
}

private func loadSettings(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func fixtureLinkState(
    at path: String,
    id: String
) throws -> (
    parentSessionId: String?,
    suggestedParentId: String?,
    linkSource: String?,
    suggestionStatus: String?,
    suggestionCandidates: String?,
    linkCheckedAt: String?
) {
    let queue = try DatabaseQueue(path: path)
    return try queue.read { db in
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT parent_session_id, suggested_parent_id, link_source,
                       suggestion_status, suggestion_candidates, link_checked_at
                FROM sessions
                WHERE id = ?
            """,
            arguments: [id]
        )
        return (
            row?["parent_session_id"] as String?,
            row?["suggested_parent_id"] as String?,
            row?["link_source"] as String?,
            row?["suggestion_status"] as String?,
            row?["suggestion_candidates"] as String?,
            row?["link_checked_at"] as String?
        )
    }
}

private func resetFixtureSuggestion(at path: String, id: String, suggestedParentId: String) throws {
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(
            sql: """
                UPDATE sessions
                SET suggested_parent_id = ?,
                    parent_session_id = NULL,
                    link_source = NULL,
                    suggestion_status = NULL,
                    suggestion_candidates = NULL,
                    link_checked_at = NULL
                WHERE id = ?
            """,
            arguments: [suggestedParentId, id]
        )
    }
}

private func setFixtureAmbiguousSuggestion(at path: String, id: String) throws {
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(
            sql: """
                UPDATE sessions
                SET suggested_parent_id = NULL,
                    parent_session_id = NULL,
                    suggestion_status = 'ambiguous',
                    suggestion_candidates = '[{"id":"s1","score":0.91}]',
                    link_source = NULL,
                    link_checked_at = datetime('now')
                WHERE id = ?
            """,
            arguments: [id]
        )
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

private actor CheckpointTestSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !signaled else { return }
        signaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func isSignaled() -> Bool {
        signaled
    }
}

private actor PeriodicScanCompletionProbe {
    private var events = 0

    func recordEvent() {
        events += 1
    }

    func eventCount() -> Int {
        events
    }
}

private final class RunnerRepoClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_777_000_000)

    var now: Date {
        lock.withLock { value }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
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

private final class ServiceSQLTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ statement: String) {
        lock.lock()
        values.append(statement)
        lock.unlock()
    }

    func statements() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class TracingServiceDatabaseReader: ServiceDatabaseReading, @unchecked Sendable {
    private let queue: DatabaseQueue

    init(path: String, recorder: ServiceSQLTraceRecorder) throws {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            db.trace { event in recorder.append(String(describing: event)) }
        }
        queue = try DatabaseQueue(path: path, configuration: configuration)
    }

    func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try queue.read(block)
    }
}

private final class BusySequenceServiceDatabaseReader: ServiceDatabaseReading, @unchecked Sendable {
    private let queue: DatabaseQueue
    private let lock = NSLock()
    private let busyReadNumbers: Set<Int>
    private let busyImmediateReadNumbers: Set<Int>
    private var normalCount = 0
    private var immediateCount = 0

    var readCount: Int {
        lock.withLock { normalCount + immediateCount }
    }

    var normalReadCount: Int { lock.withLock { normalCount } }
    var immediateReadCount: Int { lock.withLock { immediateCount } }

    init(
        path: String,
        busyReadNumbers: Set<Int> = [],
        busyImmediateReadNumbers: Set<Int> = []
    ) throws {
        self.queue = try DatabaseQueue(path: path)
        self.busyReadNumbers = busyReadNumbers
        self.busyImmediateReadNumbers = busyImmediateReadNumbers
    }

    func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        let current = lock.withLock { () -> Int in
            normalCount += 1
            return normalCount
        }
        if busyReadNumbers.contains(current) {
            throw DatabaseError(resultCode: .SQLITE_BUSY, message: "database is locked")
        }
        return try queue.read(block)
    }

    func readImmediate<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        let current = lock.withLock { () -> Int in
            immediateCount += 1
            return immediateCount
        }
        if busyImmediateReadNumbers.contains(current) {
            throw DatabaseError(resultCode: .SQLITE_BUSY, message: "database is locked")
        }
        return try queue.read(block)
    }
}
