import XCTest
import GRDB
import Darwin
import Foundation
import EngramCoreRead
import EngramCoreWrite
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
        let start = try XCTUnwrap(source.range(of: "let termMatches = CJKText.ftsMatchTerms(query)"))
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

        let settings = EngramServiceCommandHandler.ServiceAISettings.read(
            settingsPath: settingsURL,
            environment: ["ENGRAM_RUNTIME_AI_SECRETS_PATH": bridgeURL.path],
            keychainReader: { _ in nil }
        )

        XCTAssertEqual(settings.summaryConfig?.apiKey, "summary-secret")
        XCTAssertEqual(settings.titleConfig?.apiKey, "title-secret")
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
        XCTAssertTrue(source.contains("indexer: WriterStartupIndexing(writer: writer, adapters: parserAdapters)"))
        XCTAssertTrue(source.contains("adapters: parserAdapters"))
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

        XCTAssertTrue(composition.contains("SessionAdapterFactory.defaultAdapters()"))
        XCTAssertTrue(composition.contains("adapterProvider: {"))
        XCTAssertTrue(composition.contains("Self.exactArchiveAdapters("))

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
        // Idle scans must not start embedding (plan Task 4 step 4).
        let cycleStart = try XCTUnwrap(source.range(of: "runOnePeriodicIndexCycle"))
        let cycleBody = String(source[cycleStart.lowerBound...])
        XCTAssertTrue(
            cycleBody.contains("if scan.indexed > 0")
                && cycleBody.contains("periodicSessionEmbeddingBackfill"),
            "embedding backfill must be gated on indexed > 0"
        )
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
        XCTAssertTrue(body.contains("try await writer.indexRecentSessions(adapters: parserAdapters)"))
        XCTAssertTrue(body.contains("let enabledAdapters = adaptersExcludingDisabled("))
        XCTAssertTrue(body.contains("periodicParserAdapters = enabledAdapters"))
        XCTAssertTrue(body.contains("IndexJobRunner(writer: writer, adapters: periodicParserAdapters)"))
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
        let start = try XCTUnwrap(source.range(of: "private static func runIndexingLoop("))
        let end = try XCTUnwrap(source.range(of: "/// V2 composition root", options: [], range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("periodicInsightEmbeddingBackfill"))
        XCTAssertTrue(body.contains("runInsightEmbeddingBackfillBestEffort("))
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

    func testRunnerPeriodicScanSplitsWriteGateAcrossPhases() throws {
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        let start = try XCTUnwrap(source.range(of: #"gate.performWriteCommand(name: "indexRecent")"#))
        let end = try XCTUnwrap(source.range(of: "RepoDiscovery.probeRepositories", options: [], range: start.lowerBound..<source.endIndex))
        let periodicBeforeGitProbe = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(source.contains(#"performWriteCommand(name: "periodicParentBackfills")"#))
        XCTAssertTrue(source.contains(#"performWriteCommand(name: "periodicFtsDrain")"#))
        // Wave 7C M01: pure status reads use performReadCommand (no gen bump).
        XCTAssertTrue(
            source.contains(#"performReadCommand(name: "periodicIndexStatus")"#)
                || source.contains(#"performWriteCommand(name: "periodicIndexStatus")"#)
        )
        XCTAssertTrue(source.contains(#"performWriteCommand(name: "periodicRepoCandidates")"#))
        XCTAssertTrue(periodicBeforeGitProbe.contains("runRecoverableJobsOnce()"))
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
        XCTAssertTrue(source.contains("total=\\(status.total) todayParents=\\(status.todayParents)"))
        XCTAssertTrue(source.contains("total: status.total"))
        XCTAssertTrue(source.contains("todayParents: status.todayParents"))
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
            .running(total: 42, todayParents: 7, nextScanIntervalSeconds: 900)
        )
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

    func testSQLiteReadProviderBuildsResumePrimerFromMetadataWhenFtsIsMissing() async throws {
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
        """)
        XCTAssertNil(resume.error)
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

    func testExportSessionMarksTruncatedMarkdownAndJSONTranscripts() async throws {
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
            let file = oldDir.appendingPathComponent("\(id).jsonl")
            try """
            {"type":"session_meta","payload":{"id":"\(id)","cwd":"/tmp/old","model":"gpt-5"}}
            """.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: oldBase.addingTimeInterval(Double(index))],
                ofItemAtPath: file.path
            )
        }
        let newest = newDir.appendingPathComponent("zz-newest.jsonl")
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

    func testFileSystemProviderExcludesSubagentChurnFromLiveScan() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-live-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root
            .appendingPathComponent(".claude/projects/-tmp-engram", isDirectory: true)
        let subagentDir = projectDir
            .appendingPathComponent("subagents/workflows", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)

        // A real session directly under the project dir must be reported.
        let realSession = projectDir.appendingPathComponent("real.jsonl")
        try """
        {"type":"user","sessionId":"real-session","cwd":"/tmp/engram"}
        """.write(to: realSession, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: realSession.path)

        // A subagent transcript under /subagents/ is churn — it must be excluded.
        let subagentSession = subagentDir.appendingPathComponent("workflow-abc.jsonl")
        try """
        {"type":"user","sessionId":"subagent-session","cwd":"/tmp/engram"}
        """.write(to: subagentSession, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: subagentSession.path)

        let provider = FileSystemEngramServiceReadProvider(homeDirectory: root)
        let response = try await provider.liveSessions()

        let sessionIds = response.sessions.compactMap(\.sessionId)
        XCTAssertTrue(
            sessionIds.contains("real-session"),
            "A normal recent claude-code session must be reported as live"
        )
        XCTAssertFalse(
            sessionIds.contains("subagent-session"),
            "Subagent transcripts under /subagents/ must be excluded from the live scan"
        )
        XCTAssertFalse(
            response.sessions.contains { $0.filePath.contains("/subagents/") },
            "No reported live session may originate from a /subagents/ path"
        )
    }

    func testPeriodicRepoDiscoveryIsGatedBehindIndexedSessions() throws {
        // Repo discovery spawns several `git` subprocesses per cwd (up to 200).
        // It must NOT run on every idle 5-min indexing tick — only when the scan
        // actually indexed new content, mirroring the parent-backfill guard.
        let source = try serviceCoreSource("EngramService/Core/EngramServiceRunner.swift")
        var guardIndices: [String.Index] = []
        var searchStart = source.startIndex
        while let range = source.range(of: "if scan.indexed > 0", range: searchStart..<source.endIndex) {
            guardIndices.append(range.lowerBound)
            searchStart = range.upperBound
        }
        XCTAssertGreaterThanOrEqual(
            guardIndices.count, 2,
            "repo discovery must add its own `if scan.indexed > 0` guard alongside parent-backfill"
        )
        let probe = try XCTUnwrap(source.range(of: "RepoDiscovery.probeRepositories"))
        XCTAssertTrue(
            guardIndices.contains { $0 < probe.lowerBound },
            "RepoDiscovery.probeRepositories must be gated behind `if scan.indexed > 0`, not run unconditionally"
        )
        XCTAssertTrue(
            source.contains("RepoDiscoveryMaintenanceThrottle.shared")
                && source.contains("selectCandidates(repoCandidates)"),
            "repo probing must pass through the bounded maintenance throttle"
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
            body.contains("while let file = enumerator.nextObject() as? URL"),
            "liveSessions should stream candidates from FileManager enumerators"
        )
    }

    func testFileSystemProviderCachesLiveSessionsAcrossMenuCadence() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-live-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root
            .appendingPathComponent(".codex/sessions/2026/05/24", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let first = sessionDir.appendingPathComponent("first.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"first","cwd":"/tmp/engram","model":"gpt-5"}}
        """.write(to: first, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: first.path)

        let provider = FileSystemEngramServiceReadProvider(homeDirectory: root)
        let initial = try await provider.liveSessions()
        let second = sessionDir.appendingPathComponent("second.jsonl")
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
        let first = sessionDir.appendingPathComponent("first.jsonl")
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

        let second = sessionDir.appendingPathComponent("second.jsonl")
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
            let file = codexDir.appendingPathComponent("\(id).jsonl")
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
        let settingsURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("engram-settings-\(UUID().uuidString.prefix(8)).json")
        let data = try JSONSerialization.data(withJSONObject: ["disabledSources": []])
        try data.write(to: settingsURL)
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let disabled = EngramServiceRunner.readDisabledSources(
            environment: [:],
            settingsURL: settingsURL
        )

        XCTAssertEqual(disabled, ArchivedDefaultOffSources.ids)
    }

    func testReadDisabledSourcesMergesArchivedDefaultsIntoLegacyList() throws {
        let settingsURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("engram-settings-\(UUID().uuidString.prefix(8)).json")
        let data = try JSONSerialization.data(withJSONObject: ["disabledSources": ["codex"]])
        try data.write(to: settingsURL)
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let disabled = EngramServiceRunner.readDisabledSources(
            environment: [:],
            settingsURL: settingsURL
        )

        XCTAssertEqual(disabled, ArchivedDefaultOffSources.ids.union(["codex"]))
    }

    func testReadDisabledSourcesHonorsMigratedExplicitEmptyList() throws {
        let settingsURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("engram-settings-\(UUID().uuidString.prefix(8)).json")
        let data = try JSONSerialization.data(
            withJSONObject: [
                "disabledSources": [],
                ArchivedDefaultOffSources.settingsMigrationKey: true,
            ]
        )
        try data.write(to: settingsURL)
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let disabled = EngramServiceRunner.readDisabledSources(
            environment: [:],
            settingsURL: settingsURL
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
        XCTAssertTrue(["started", "running"].contains(titles.status))
        XCTAssertNil(titles.total)
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
                        ('p1', 0, '2026-06-25', '2026-06-25T10:00:00Z', 'wk-a',
                         'A', 'intent A', 'outcome A', 'implementation', 'completed', '[]', 0.9),
                        ('p1', 1, '2026-06-25', '2026-06-25T10:05:00Z', 'wk-b',
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
            try writer.read { db -> (Int, Int) in
                let embeddings = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insight_embeddings") ?? 0
                let probes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embedding_gate_probe") ?? 0
                return (embeddings, probes)
            }
        }.value
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
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
