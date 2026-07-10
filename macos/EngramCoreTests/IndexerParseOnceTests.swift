import Foundation
import GRDB
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

/// Coverage for the single-parse indexing path (finding #17) and the
/// provable-skip digest short-circuit (finding #18).
final class IndexerParseOnceTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("parse-once-\(UUID().uuidString).sqlite")
        writer = try EngramDatabaseWriter(path: tempDB.path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let tempDB {
            try? FileManager.default.removeItem(at: tempDB)
        }
        tempDB = nil
    }

    // MARK: - #17: single parse per changed file

    /// The production single-parse override must produce byte-identical
    /// `(info, messages)` to the separate `parseSessionInfo` + `streamMessages`
    /// passes it replaces.
    func testClaudeCodeScanForIndexingMatchesSeparateParses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parse-once-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("session.jsonl").path
        let lines = [
            #"{"type":"user","sessionId":"claude-a","cwd":"/Users/test/proj","timestamp":"2026-01-01T10:00:00Z","message":{"role":"user","content":"implement the login fix"}}"#,
            #"{"type":"assistant","sessionId":"claude-a","timestamp":"2026-01-01T10:01:00Z","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"text","text":"done and verified"}],"usage":{"input_tokens":100,"output_tokens":50}}}"#,
            #"{"type":"user","sessionId":"claude-a","timestamp":"2026-01-01T10:02:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(toFile: locator, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)

        guard case .success(let expectedInfo) = try await adapter.parseSessionInfo(locator: locator) else {
            return XCTFail("parseSessionInfo failed on fixture")
        }
        var expectedMessages: [NormalizedMessage] = []
        let stream = try await adapter.streamMessages(locator: locator, options: StreamMessagesOptions())
        for try await message in stream {
            expectedMessages.append(message)
        }

        guard case .success(let scan) = try await adapter.scanForIndexing(locator: locator) else {
            return XCTFail("scanForIndexing failed on fixture")
        }

        XCTAssertEqual(scan.info, expectedInfo, "single-parse info must match parseSessionInfo")
        XCTAssertEqual(scan.messages, expectedMessages, "single-parse messages must match streamMessages")
    }

    /// The indexer must route each changed file through `scanForIndexing` exactly
    /// once and never fall back to the old two-pass `parseSessionInfo` +
    /// `streamMessages` sequence.
    func testIndexerParsesEachChangedFileExactlyOnce() async throws {
        let adapter = ParseCountingSessionAdapter(locators: ["/tmp/a.jsonl", "/tmp/b.jsonl"])
        let indexer = SwiftIndexer(
            sink: CollectingNoopSink(),
            adapters: [adapter],
            authoritativeNode: "test-node"
        )
        let snapshots = try await indexer.collectSnapshots()

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(adapter.scanForIndexingCalls, 2, "each file must be parsed once via scanForIndexing")
        XCTAssertEqual(adapter.parseSessionInfoCalls, 0, "the separate info pass must not run")
        XCTAssertEqual(adapter.streamMessagesCalls, 0, "the separate message pass must not run")
    }

    // MARK: - #18: provable-skip digest short-circuit

    /// Provable-skip sessions must not persist implementation-digest work beats,
    /// while their observable fields (tier, counts, costs, tools, instruction
    /// signals) stay identical to a non-skip session with the same content.
    func testProvableSkipSkipsDigestButPreservesObservableFields() async throws {
        let rich: [NormalizedMessage] = [
            NormalizedMessage(role: .user, content: "实现项目变更时间线第一版", timestamp: "2026-01-01T10:00:00Z"),
            NormalizedMessage(
                role: .assistant,
                content: "结果\n已完成第一版项目变更时间线。\n\n验证结果\nchecks run: targeted tests",
                timestamp: "2026-01-01T10:01:00Z",
                toolCalls: [NormalizedToolCall(name: "edit_file")],
                usage: TokenUsage(inputTokens: 100, outputTokens: 50)
            ),
        ]
        let liteMessages: [NormalizedMessage] = [
            NormalizedMessage(role: .user, content: "问题一", timestamp: "2026-01-01T10:00:00Z"),
            NormalizedMessage(role: .user, content: "问题二", timestamp: "2026-01-01T10:01:00Z"),
        ]

        let adapter = MatrixSyntheticAdapter(sessions: [
            "/repo/normal.jsonl": .init(id: "normal", agentRole: nil, messages: rich, messageCountOverride: 5),
            "/repo/premium.jsonl": .init(id: "premium", agentRole: nil, messages: rich, messageCountOverride: 25),
            "/repo/proj/subagents/child.jsonl": .init(id: "subagent", agentRole: nil, messages: rich, messageCountOverride: 5),
            "/repo/dispatched.jsonl": .init(id: "dispatched", agentRole: "dispatched", messages: rich, messageCountOverride: 5),
            "/repo/lite.jsonl": .init(id: "lite", agentRole: nil, messages: liteMessages, messageCountOverride: 2),
        ])

        let indexer = SwiftIndexer(sink: CollectingNoopSink(), adapters: [adapter], authoritativeNode: "local")
        let snapshots = try await indexer.collectSnapshots()

        try writer.write { db in
            let sink = SessionBatchUpsert(db: db)
            _ = try sink.upsertBatch(snapshots, reason: .initialScan)

            func tier(_ id: String) throws -> String? {
                try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = ?", arguments: [id])
            }
            func beatCount(_ id: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_work_beats WHERE session_id = ?", arguments: [id]) ?? -1
            }
            func inputTokens(_ id: String) throws -> Int? {
                try Int.fetchOne(db, sql: "SELECT input_tokens FROM session_costs WHERE session_id = ?", arguments: [id])
            }
            func toolCount(_ id: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_tools WHERE session_id = ?", arguments: [id]) ?? -1
            }

            // Tier verdicts are unchanged by the short-circuit.
            XCTAssertEqual(try tier("normal"), "normal")
            XCTAssertEqual(try tier("premium"), "premium")
            XCTAssertEqual(try tier("lite"), "lite")
            XCTAssertEqual(try tier("subagent"), "skip")
            XCTAssertEqual(try tier("dispatched"), "skip")

            // Non-skip sessions still get their digest beats.
            let normalBeats = try beatCount("normal")
            XCTAssertGreaterThan(normalBeats, 0, "non-skip session must still produce work beats")
            XCTAssertGreaterThan(try beatCount("premium"), 0)

            // Provable-skip sessions skip the digest entirely.
            XCTAssertEqual(try beatCount("subagent"), 0, "subagent-path skip must not persist work beats")
            XCTAssertEqual(try beatCount("dispatched"), 0, "agent-role skip must not persist work beats")

            // ...but their observable fields are preserved byte-for-byte.
            XCTAssertEqual(try inputTokens("subagent"), 100, "skip-session costs must be preserved")
            XCTAssertEqual(try inputTokens("dispatched"), 100, "skip-session costs must be preserved")
            XCTAssertEqual(try inputTokens("normal"), 100)
            XCTAssertEqual(try toolCount("subagent"), 1, "skip-session tool counts must be preserved")
            XCTAssertEqual(try toolCount("normal"), 1)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT summary_message_count FROM sessions WHERE id = 'subagent'"),
                2,
                "skip-session message counts must be preserved"
            )
            XCTAssertNotNil(
                try Int.fetchOne(db, sql: "SELECT instruction_count FROM sessions WHERE id = 'subagent'"),
                "skip-session instruction signals must still be computed (claude-code source)"
            )
        }
    }

    // MARK: - #tail-parse: append-only Claude JSONL checkpointing

    func testClaudeCodeTailParseAppendMatchesFullReindex() async throws {
        let fixture = try makeClaudeFixture(name: "tail-parity")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeClaudeLines(mergeSafeClaudeLines(), to: fixture.locator)
        let adapter = CountingTailAdapter(projectsRoot: fixture.root.path)

        let initialResult = try await writer.indexRecentSessions(adapters: [adapter])
        XCTAssertEqual(initialResult.indexed, 1)
        try await drainFtsJobs(writer, adapter: adapter)
        XCTAssertEqual(adapter.scanForIndexingCalls, 1)
        XCTAssertEqual(adapter.scanTailForIndexingCalls, 0)
        let initialState = try fileState(locator: indexedLocator(fixture.locator))
        let initialStateDiagnostics = try fileIndexStateDiagnostics()
        XCTAssertEqual(
            initialState?.parsedOffset,
            Int64(try Data(contentsOf: fixture.locator).count),
            initialStateDiagnostics
        )
        XCTAssertNotNil(
            initialState?.boundaryHash,
            "successful JSONL parses must persist a reusable boundary hash: \(initialStateDiagnostics)"
        )

        try appendText(tailClaudeLines().joined(separator: "\n") + "\n", to: fixture.locator)
        _ = try await writer.indexRecentSessions(adapters: [adapter])
        try await drainFtsJobs(writer, adapter: adapter)
        // Wave 7A H10: content fingerprint cannot be extended without re-reading
        // prior messages, so append falls back to a full reparse after a tail probe.
        XCTAssertEqual(adapter.scanTailForIndexingCalls, 1, "must still attempt the tail path first")
        XCTAssertGreaterThanOrEqual(
            adapter.scanForIndexingCalls,
            2,
            "append pass full-reparses so content fingerprint stays parity-stable"
        )

        let fullDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("tail-full-\(UUID().uuidString).sqlite")
        let fullWriter = try EngramDatabaseWriter(path: fullDB.path)
        defer {
            try? FileManager.default.removeItem(at: fullDB)
        }
        try fullWriter.migrate()
        _ = try await fullWriter.indexRecentSessions(adapters: [adapter])
        try await drainFtsJobs(fullWriter, adapter: adapter)

        for table in stableParityTables {
            XCTAssertEqual(
                try stableRows(writer, table.sql),
                try stableRows(fullWriter, table.sql),
                table.name
            )
        }
        XCTAssertEqual(try ftsHits(writer, "tailonlysearchtoken"), 1)
        XCTAssertEqual(try ftsHits(fullWriter, "tailonlysearchtoken"), 1)
    }

    func testClaudeCodeTailParseNoTrailingNewlineFallsBackWithoutDoubleCounting() async throws {
        let fixture = try makeClaudeFixture(name: "tail-no-newline")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try mergeSafeClaudeLines().joined(separator: "\n").write(to: fixture.locator, atomically: false, encoding: .utf8)
        let adapter = CountingTailAdapter(projectsRoot: fixture.root.path)

        _ = try await writer.indexRecentSessions(adapters: [adapter])
        let initialState = try XCTUnwrap(fileState(locator: indexedLocator(fixture.locator)))
        XCTAssertLessThan(initialState.parsedOffset, initialState.sizeBytes)
        XCTAssertNil(initialState.boundaryHash, "EOF-remainder parses must not be eligible for tail resume")

        try appendText("\n" + tailClaudeLines().joined(separator: "\n") + "\n", to: fixture.locator)
        _ = try await writer.indexRecentSessions(adapters: [adapter])
        XCTAssertEqual(adapter.scanTailForIndexingCalls, 0)
        XCTAssertEqual(adapter.scanForIndexingCalls, 2)

        let fullDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("tail-no-newline-full-\(UUID().uuidString).sqlite")
        let fullWriter = try EngramDatabaseWriter(path: fullDB.path)
        defer {
            try? FileManager.default.removeItem(at: fullDB)
        }
        try fullWriter.migrate()
        _ = try await fullWriter.indexRecentSessions(adapters: [ClaudeCodeAdapter(projectsRoot: fixture.root.path)])

        for table in stableParityTables where table.name != "session_index_jobs" && table.name != "sessions_fts" {
            XCTAssertEqual(
                try stableRows(writer, table.sql),
                try stableRows(fullWriter, table.sql),
                table.name
            )
        }
        XCTAssertEqual(try sessionIntValue("message_count", id: "tail-session"), 8)
    }

    func testClaudeCodeTailParseRewriteInPlaceFallsBackToFullReparse() async throws {
        let fixture = try makeClaudeFixture(name: "tail-rewrite")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeClaudeLines(baseClaudeLines(firstUser: "Initial summary before rewrite"), to: fixture.locator)
        let adapter = ClaudeCodeAdapter(projectsRoot: fixture.root.path)

        _ = try await writer.indexRecentSessions(adapters: [adapter])
        let before = try XCTUnwrap(fileState(locator: indexedLocator(fixture.locator)))
        XCTAssertNotNil(before.boundaryHash)

        let rewritten = baseClaudeLines(firstUser: "Rewritten summary after mismatch") + tailClaudeLines()
        try replaceFilePreservingIdentity(fixture.locator, with: rewritten.joined(separator: "\n") + "\n")
        _ = try await writer.indexRecentSessions(adapters: [adapter])

        let summary = try sessionValue("summary", id: "tail-session")
        XCTAssertEqual(summary, "Rewritten summary after mismatch")
        let after = try XCTUnwrap(fileState(locator: indexedLocator(fixture.locator)))
        XCTAssertGreaterThan(after.parsedOffset, before.parsedOffset)
        XCTAssertNotEqual(after.boundaryHash, before.boundaryHash)
    }

    func testClaudeCodeTailParseTruncationFallsBackToFullReparse() async throws {
        let fixture = try makeClaudeFixture(name: "tail-truncate")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeClaudeLines(baseClaudeLines() + tailClaudeLines(), to: fixture.locator)
        let adapter = ClaudeCodeAdapter(projectsRoot: fixture.root.path)

        _ = try await writer.indexRecentSessions(adapters: [adapter])
        let before = try XCTUnwrap(fileState(locator: indexedLocator(fixture.locator)))

        try replaceFilePreservingIdentity(fixture.locator, with: baseClaudeLines().joined(separator: "\n") + "\n")
        _ = try await writer.indexRecentSessions(adapters: [adapter])

        let after = try XCTUnwrap(fileState(locator: indexedLocator(fixture.locator)))
        XCTAssertLessThan(after.sizeBytes, before.sizeBytes)
        XCTAssertEqual(try sessionIntValue("message_count", id: "tail-session"), 2)
    }

    func testClaudeCodeTailParseDoesNotAdvancePastPartialLineAndLaterIndexesIt() async throws {
        let fixture = try makeClaudeFixture(name: "tail-partial")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeClaudeLines(baseClaudeLines(), to: fixture.locator)
        let adapter = ClaudeCodeAdapter(projectsRoot: fixture.root.path)

        _ = try await writer.indexRecentSessions(adapters: [adapter])
        try await drainFtsJobs(writer, adapter: adapter)
        let completeOffset = try XCTUnwrap(fileState(locator: indexedLocator(fixture.locator))?.parsedOffset)
        XCTAssertEqual(completeOffset, Int64(try Data(contentsOf: fixture.locator).count))

        try appendText(
            #"{"type":"user","sessionId":"tail-session","cwd":"/Users/test/project","timestamp":"2026-01-01T10:02:00Z","message":{"role":"user","content":"partial tail request"#,
            to: fixture.locator
        )
        _ = try await writer.indexRecentSessions(adapters: [adapter])

        let partialState = try XCTUnwrap(fileState(locator: indexedLocator(fixture.locator)))
        XCTAssertEqual(partialState.parsedOffset, completeOffset, "checkpoint must stop before the unterminated JSONL line")
        XCTAssertEqual(try sessionIntValue("message_count", id: "tail-session"), 2)

        try appendText(#" completed"}}"# + "\n" + tailAssistantLine(keyword: "partialcompletesearchtoken") + "\n", to: fixture.locator)
        _ = try await writer.indexRecentSessions(adapters: [adapter])
        try await drainFtsJobs(writer, adapter: adapter)

        let finalState = try XCTUnwrap(fileState(locator: indexedLocator(fixture.locator)))
        XCTAssertEqual(finalState.parsedOffset, Int64(try Data(contentsOf: fixture.locator).count))
        XCTAssertEqual(try sessionIntValue("message_count", id: "tail-session"), 4)
        XCTAssertEqual(try ftsHits(writer, "partialcompletesearchtoken"), 1)
    }

    func testClaudeCodeTailParseNoVisibleCompleteTailFallsBackAndRefreshesSize() async throws {
        let fixture = try makeClaudeFixture(name: "tail-empty-visible")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeClaudeLines(mergeSafeClaudeLines(), to: fixture.locator)
        let adapter = CountingTailAdapter(projectsRoot: fixture.root.path)

        _ = try await writer.indexRecentSessions(adapters: [adapter])
        let initialSize = try XCTUnwrap(fileState(locator: indexedLocator(fixture.locator))?.sizeBytes)
        try appendText(#"{"type":"user","sessionId":"tail-session","timestamp":"2026-01-01T10:09:00Z","message":{"role":"user","content":[{"type":"tool_result","content":""}]}}"# + "\n", to: fixture.locator)
        _ = try await writer.indexRecentSessions(adapters: [adapter])

        let finalState = try XCTUnwrap(fileState(locator: indexedLocator(fixture.locator)))
        XCTAssertGreaterThan(finalState.sizeBytes, initialSize)
        XCTAssertEqual(finalState.sizeBytes, try sessionInt64Value("size_bytes", id: "tail-session"))
        XCTAssertEqual(adapter.scanTailForIndexingCalls, 1)
        XCTAssertEqual(adapter.scanForIndexingCalls, 2, "complete no-visible tails must full-reparse to refresh session size")
    }

    private struct StableParityTable {
        var name: String
        var sql: String
    }

    private var stableParityTables: [StableParityTable] {
        [
            StableParityTable(
                name: "sessions",
                sql: """
                SELECT id, source, start_time, end_time, cwd, project, model,
                       message_count, user_message_count, assistant_message_count,
                       tool_message_count, system_message_count, summary,
                       summary_message_count, instruction_count, human_turn_count,
                       instruction_summary, source_locator, size_bytes, origin,
                       authoritative_node, sync_version, snapshot_hash, tier,
                       agent_role, parent_session_id, link_source
                  FROM sessions
                 ORDER BY id
                """
            ),
            StableParityTable(
                name: "session_costs",
                sql: """
                SELECT session_id, model, input_tokens, output_tokens,
                       cache_read_tokens, cache_creation_tokens, cost_usd
                  FROM session_costs
                 ORDER BY session_id, model
                """
            ),
            StableParityTable(
                name: "session_tools",
                sql: """
                SELECT session_id, tool_name, call_count
                  FROM session_tools
                 ORDER BY session_id, tool_name
                """
            ),
            StableParityTable(
                name: "session_work_beats",
                sql: """
                SELECT session_id, beat_index, action_date, action_timestamp,
                       work_key, work_title, human_intent, assistant_outcome,
                       kind, status, operation_events, confidence
                  FROM session_work_beats
                 ORDER BY session_id, beat_index
                """
            ),
            StableParityTable(
                name: "session_index_jobs",
                sql: """
                SELECT session_id, job_kind, target_sync_version, status, retry_count
                  FROM session_index_jobs
                 ORDER BY session_id, job_kind, status
                """
            ),
            StableParityTable(
                name: "file_index_state",
                sql: """
                SELECT source, locator, size_bytes, inode, device, parsed_offset,
                       boundary_hash, parse_status, failure_kind, retry_after,
                       retry_count, last_error, schema_version
                  FROM file_index_state
                 ORDER BY source, locator
                """
            ),
            StableParityTable(
                name: "sessions_fts",
                sql: """
                SELECT session_id, content
                  FROM sessions_fts
                 ORDER BY session_id, content
                """
            ),
        ]
    }

    private func makeClaudeFixture(name: String) throws -> (root: URL, locator: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-Users-test-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return (root, project.appendingPathComponent("tail-session.jsonl"))
    }

    private func baseClaudeLines(firstUser: String = "Initial implementation request") -> [String] {
        [
            claudeUserLine(content: firstUser, timestamp: "2026-01-01T10:00:00Z"),
            claudeAssistantLine(content: "Initial implementation done. checks run", timestamp: "2026-01-01T10:01:00Z", input: 10, output: 5),
        ]
    }

    private func mergeSafeClaudeLines() -> [String] {
        [
            claudeUserLine(content: "Initial implementation request", timestamp: "2026-01-01T10:00:00Z"),
            claudeAssistantLine(content: "Initial implementation done. checks run", timestamp: "2026-01-01T10:01:00Z", input: 10, output: 5),
            claudeUserLine(content: "Second implementation request", timestamp: "2026-01-01T10:01:10Z"),
            claudeAssistantLine(content: "Second implementation done. checks run", timestamp: "2026-01-01T10:01:20Z", input: 8, output: 4),
            claudeUserLine(content: "Third implementation request", timestamp: "2026-01-01T10:01:30Z"),
            claudeAssistantLine(content: "Third implementation done. checks run", timestamp: "2026-01-01T10:01:40Z", input: 7, output: 3),
        ]
    }

    private func tailClaudeLines() -> [String] {
        [
            claudeUserLine(content: "Add the tail parse coverage", timestamp: "2026-01-01T10:02:00Z"),
            claudeAssistantLine(content: "Tail parse completed with tailonlysearchtoken. checks run", timestamp: "2026-01-01T10:03:00Z", input: 4, output: 2),
        ]
    }

    private func tailAssistantLine(keyword: String) -> String {
        claudeAssistantLine(content: "Partial line completed with \(keyword). checks run", timestamp: "2026-01-01T10:03:00Z", input: 3, output: 2)
    }

    private func claudeUserLine(content: String, timestamp: String) -> String {
        let payload: [String: Any] = [
            "type": "user",
            "sessionId": "tail-session",
            "cwd": "/Users/test/project",
            "timestamp": timestamp,
            "message": [
                "role": "user",
                "content": content,
            ],
        ]
        return jsonLine(payload)
    }

    private func claudeAssistantLine(content: String, timestamp: String, input: Int, output: Int) -> String {
        let payload: [String: Any] = [
            "type": "assistant",
            "sessionId": "tail-session",
            "timestamp": timestamp,
            "message": [
                "role": "assistant",
                "model": "claude-sonnet-4-6",
                "content": [
                    [
                        "type": "tool_use",
                        "id": "tool-\(input)-\(output)",
                        "name": "Edit",
                        "input": ["file": "tail.swift"],
                    ],
                    [
                        "type": "text",
                        "text": content,
                    ],
                ],
                "usage": [
                    "input_tokens": input,
                    "output_tokens": output,
                ],
            ],
        ]
        return jsonLine(payload)
    }

    private func jsonLine(_ payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8)!
    }

    private func writeClaudeLines(_ lines: [String], to locator: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: locator, atomically: false, encoding: .utf8)
    }

    private func appendText(_ text: String, to locator: URL) throws {
        let handle = try FileHandle(forWritingTo: locator)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func replaceFilePreservingIdentity(_ locator: URL, with text: String) throws {
        let handle = try FileHandle(forWritingTo: locator)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func fileState(locator: String) throws -> FileIndexState? {
        var locators = [locator]
        if locator.hasPrefix("/var/") {
            locators.append("/private\(locator)")
        }
        let states = try writer.knownFileIndexStates(source: .claudeCode, locators: locators)
        return states[locator] ?? locators.lazy.compactMap { states[$0] }.first
    }

    private func indexedLocator(_ locator: URL) -> String {
        locator.resolvingSymlinksInPath().path
    }

    private func fileIndexStateDiagnostics() throws -> String {
        try stableRows(
            writer,
            """
            SELECT source, locator, size_bytes, parsed_offset, boundary_hash, parse_status
              FROM file_index_state
             ORDER BY source, locator
            """
        ).joined(separator: "\n")
    }

    private func sessionValue(_ column: String, id: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT \(column) FROM sessions WHERE id = ?", arguments: [id])
        }
    }

    private func sessionIntValue(_ column: String, id: String) throws -> Int? {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT \(column) FROM sessions WHERE id = ?", arguments: [id])
        }
    }

    private func sessionInt64Value(_ column: String, id: String) throws -> Int64? {
        try writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT \(column) FROM sessions WHERE id = ?", arguments: [id])
        }
    }

    private func drainFtsJobs(_ writer: EngramDatabaseWriter, adapter: any SessionAdapter) async throws {
        _ = try await IndexJobRunner(writer: writer, adapters: [adapter]).runRecoverableJobs()
    }

    private func ftsHits(_ writer: EngramDatabaseWriter, _ query: String) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sessions_fts WHERE sessions_fts MATCH ?",
                arguments: [query]
            ) ?? 0
        }
    }

    private func stableRows(_ writer: EngramDatabaseWriter, _ sql: String) throws -> [String] {
        try writer.read { db in
            try Row.fetchAll(db, sql: sql).map { row in
                row.columnNames.map { column in
                    "\(column)=\(self.stableValue(row[column]))"
                }
                .joined(separator: "|")
            }
        }
    }

    private func stableValue(_ value: DatabaseValue) -> String {
        switch value.storage {
        case .null:
            return "<null>"
        case .int64(let value):
            return "\(value)"
        case .double(let value):
            return "\(value)"
        case .string(let value):
            return value
        case .blob(let data):
            return data.base64EncodedString()
        }
    }
}

// MARK: - Test doubles

/// Minimal write sink for `collectSnapshots`, which never calls `upsertBatch`.
private struct CollectingNoopSink: IndexingWriteSink {
    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        SessionBatchUpsertResult(reason: reason, results: [])
    }
}

// MARK: - Test adapters

private final class CountingTailAdapter: TailIndexingSessionAdapter {
    let source: SourceName = .claudeCode
    private let inner: ClaudeCodeAdapter
    private(set) var scanForIndexingCalls = 0
    private(set) var scanTailForIndexingCalls = 0

    init(projectsRoot: String) {
        self.inner = ClaudeCodeAdapter(projectsRoot: projectsRoot)
    }

    func detect() async -> Bool {
        await inner.detect()
    }

    func listSessionLocators() async throws -> [String] {
        try await inner.listSessionLocators()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        try await inner.parseSessionInfo(locator: locator)
    }

    func isAccessible(locator: String) async -> Bool {
        await inner.isAccessible(locator: locator)
    }

    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        scanForIndexingCalls += 1
        return try await inner.scanForIndexing(locator: locator)
    }

    func scanTailForIndexing(
        locator: String,
        from parsedOffset: Int64,
        expectedBoundaryHash: String
    ) async throws -> IndexingTailScanResult {
        scanTailForIndexingCalls += 1
        return try await inner.scanTailForIndexing(
            locator: locator,
            from: parsedOffset,
            expectedBoundaryHash: expectedBoundaryHash
        )
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        try await inner.streamMessages(locator: locator, options: options)
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        try await inner.streamMessagesWithMetadata(locator: locator, options: options)
    }
}

/// Counts which parse entry points the indexer invokes. Its single-parse
/// override builds `(info, messages)` without touching the two-pass methods, so
/// the counters prove the indexer took the combined path.
private final class ParseCountingSessionAdapter: SessionAdapter {
    let source: SourceName = .claudeCode
    private let locators: [String]
    private(set) var parseSessionInfoCalls = 0
    private(set) var streamMessagesCalls = 0
    private(set) var scanForIndexingCalls = 0

    init(locators: [String]) {
        self.locators = locators
    }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { locators }
    func isAccessible(locator: String) async -> Bool { true }

    private func info(for locator: String) -> NormalizedSessionInfo {
        NormalizedSessionInfo(
            id: URL(fileURLWithPath: locator).deletingPathExtension().lastPathComponent,
            source: source,
            startTime: "2026-01-01T10:00:00Z",
            cwd: "/repo",
            project: "proj",
            model: "synthetic",
            messageCount: 4,
            userMessageCount: 1,
            assistantMessageCount: 1,
            toolMessageCount: 0,
            systemMessageCount: 0,
            summary: "hello",
            filePath: locator,
            sizeBytes: 128
        )
    }

    private var messages: [NormalizedMessage] {
        [
            NormalizedMessage(role: .user, content: "do the thing"),
            NormalizedMessage(role: .assistant, content: "done"),
        ]
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        parseSessionInfoCalls += 1
        return .success(info(for: locator))
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        streamMessagesCalls += 1
        let items = messages
        return AsyncThrowingStream { continuation in
            for message in items { continuation.yield(message) }
            continuation.finish()
        }
    }

    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        scanForIndexingCalls += 1
        return .success(IndexingScan(info: info(for: locator), messages: messages))
    }
}

/// Serves fully controlled `(info, messages)` per locator so tier/skip cases can
/// be constructed precisely. Uses the default two-pass `scanForIndexing`.
private final class MatrixSyntheticAdapter: SessionAdapter {
    struct Session {
        var id: String
        var agentRole: String?
        var messages: [NormalizedMessage]
        var messageCountOverride: Int?
    }

    let source: SourceName = .claudeCode
    private let sessions: [String: Session]

    init(sessions: [String: Session]) {
        self.sessions = sessions
    }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { sessions.keys.sorted() }
    func isAccessible(locator: String) async -> Bool { true }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        guard let session = sessions[locator] else { return .failure(.fileMissing) }
        let user = session.messages.filter { $0.role == .user }.count
        let assistant = session.messages.filter { $0.role == .assistant }.count
        let tool = session.messages.filter { $0.role == .tool }.count
        return .success(
            NormalizedSessionInfo(
                id: session.id,
                source: source,
                startTime: "2026-01-01T10:00:00Z",
                cwd: "/repo",
                project: "proj",
                model: "claude-opus-4-6",
                messageCount: session.messageCountOverride ?? (user + assistant + tool),
                userMessageCount: user,
                assistantMessageCount: assistant,
                toolMessageCount: tool,
                systemMessageCount: 0,
                summary: "hello",
                filePath: locator,
                sizeBytes: 128,
                agentRole: session.agentRole
            )
        )
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        let items = sessions[locator]?.messages ?? []
        return AsyncThrowingStream { continuation in
            for message in items { continuation.yield(message) }
            continuation.finish()
        }
    }
}
