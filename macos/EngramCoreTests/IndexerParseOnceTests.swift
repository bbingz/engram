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

    func testCodexScanForIndexingDoesNotDelegateToTwoReadPaths_repro() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/EngramCore/Adapters/Sources/CodexAdapter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func scanForIndexing(locator:"))
        let end = try XCTUnwrap(source.range(of: "func scanTailForIndexing(", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]

        XCTAssertFalse(body.contains("parseSessionInfo(locator:"))
        XCTAssertFalse(body.contains("Self.messages(\n            locator:"))
        XCTAssertTrue(body.contains("JSONLAdapterSupport.readObjects("))
    }

    func testCopilotScanForIndexingDoesNotDelegateToTwoReadPaths_repro() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/EngramCore/Adapters/Sources/CopilotAdapter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func scanForIndexing(locator:"))
        let end = try XCTUnwrap(source.range(of: "func streamMessages(", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]

        XCTAssertFalse(body.contains("parseSessionInfo(locator:"))
        XCTAssertFalse(body.contains("streamMessagesWithMetadata("))
        XCTAssertEqual(body.components(separatedBy: "JSONLAdapterSupport.readObjects(").count - 1, 1)
    }

    func testCopilotCheckpointScanUsesOneCompositeSnapshot_repro() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/EngramCore/Adapters/Sources/CopilotAdapter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func scanForIndexing(locator:"))
        let end = try XCTUnwrap(source.range(of: "func streamMessages(", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]

        XCTAssertEqual(body.components(separatedBy: "checkpointSnapshot(locator:").count - 1, 1)
        XCTAssertFalse(body.contains("parseCheckpointSessionInfo(locator:"))
        XCTAssertFalse(body.contains("checkpointMessages(locator:"))
    }

    func testCopilotBypassesMainFileShortcutForCompositeInputs_repro() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EngramCoreWrite/Indexing/SwiftIndexer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private static func usesCompositeInputs"))
        let body = source[start.lowerBound...]

        XCTAssertTrue(body.contains(".copilot"))
    }

    func testCursorBypassesMainFileShortcutForCompositeInputs_repro() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EngramCoreWrite/Indexing/SwiftIndexer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private static func usesCompositeInputs"))
        let body = source[start.lowerBound...]

        XCTAssertTrue(body.contains(".cursor"))
    }

    func testCursorModernVirtualLocatorCannotUseUnconfinedDirectFileStat_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-modern-stat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store.db")
        try Data("cursor store".utf8).write(to: store)
        let payload = try JSONSerialization.data(withJSONObject: [
            "sessionId": "cursor-modern-stat",
            "storeDBPath": store.path,
        ])
        let locator = "cursor-modern:\(payload.base64EncodedString())"

        XCTAssertNil(
            FileIndexStat.directFileStat(locator: locator),
            "modern Cursor locators require adapter-owned cursorDataRoot validation"
        )
    }

    func testCopilotRecentCompositeInputsDeferDirtyIdentityWithoutSuccess_repro() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EngramCoreWrite/Indexing/SwiftIndexer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("adapter.source == .copilot"))
        XCTAssertTrue(source.contains("currentStat.legacyState.modifiedAt > activeFileCutoff"))
        XCTAssertTrue(source.contains("scan.parseFailure == nil"))
    }

    // Audit IDX-PARTIAL-001: a capped full scan must not replace a complete snapshot.
    func testCodexTruncatedIndexScanDoesNotReplaceCompleteSnapshot_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-truncated-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("rollout-codex-truncated-index.jsonl")
        let lines: [[String: Any]] = [
            ["timestamp": "2026-06-01T10:00:00.000Z", "type": "session_meta",
             "payload": ["id": "codex-truncated-index-1", "timestamp": "2026-06-01T10:00:00.000Z", "cwd": "/tmp/codex-index"]],
            ["timestamp": "2026-06-01T10:00:01.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "First request"]]]],
            ["timestamp": "2026-06-01T10:00:02.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "First response"]]]],
            ["timestamp": "2026-06-01T10:00:03.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Second request"]]]],
            ["timestamp": "2026-06-01T10:00:04.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Second response"]]]],
            ["timestamp": "2026-06-01T10:00:05.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Third request"]]]],
            ["timestamp": "2026-06-01T10:00:06.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Third response"]]]],
        ]
        try (lines.map(jsonLine).joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let completeAdapter = CodexAdapter(
            sessionsRoot: root.path,
            limits: ParserLimits(maxMessages: 100)
        )
        let first = try await writer.indexRecentSessions(adapters: [completeAdapter])
        let locator = try XCTUnwrap(sessionValue("source_locator", id: "codex-truncated-index-1"))
        let firstMessageCount = try sessionIntValue("message_count", id: "codex-truncated-index-1")
        let firstSnapshotHash = try XCTUnwrap(sessionValue("snapshot_hash", id: "codex-truncated-index-1"))
        var firstState = try XCTUnwrap(
            writer.knownFileIndexStates(source: .codex, locators: [locator])[locator]
        )

        XCTAssertEqual(first.indexed, 1)
        XCTAssertEqual(firstMessageCount, 6)
        XCTAssertEqual(firstState.parseStatus, .ok)

        firstState.schemaVersion = FileIndexState.currentSchemaVersion - 1
        try writer.upsertFileIndexState(firstState)

        let cappedAdapter = CodexAdapter(
            sessionsRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let second = try await writer.indexRecentSessions(adapters: [cappedAdapter])
        let secondState = try XCTUnwrap(
            writer.knownFileIndexStates(source: .codex, locators: [locator])[locator]
        )

        XCTAssertEqual(second.indexed, 0)
        XCTAssertEqual(try sessionIntValue("message_count", id: "codex-truncated-index-1"), firstMessageCount)
        XCTAssertEqual(try sessionValue("snapshot_hash", id: "codex-truncated-index-1"), firstSnapshotHash)
        XCTAssertEqual(secondState.parseStatus, .terminal)
        XCTAssertEqual(secondState.failureKind, .messageLimitExceeded)
        XCTAssertNil(secondState.retryAfterEpochSeconds)
        XCTAssertEqual(secondState.retryCount, 0)
        XCTAssertEqual(secondState.lastError, "messageLimitExceeded")
    }

    func testCopilotCappedCompositeIndexesPrefixAndRecordsTerminalIdentity_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-capped-index-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("copilot-capped", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "id: copilot-capped\ncwd: /tmp/copilot-capped\n"
            .write(to: session.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let events = session.appendingPathComponent("events.jsonl")
        try [
            #"{"type":"user.message","data":{"content":"first"}}"#,
            #"{"type":"assistant.message","data":{"content":"second"}}"#,
            #"{"type":"user.message","data":{"content":"third"}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(sessionRoot: root.path, limits: ParserLimits(maxMessages: 2))
        let expectedIdentity = try XCTUnwrap(adapter.indexingInputIdentity(locator: events.path))
        let result = try await writer.indexRecentSessions(adapters: [adapter])
        let indexedEvents = events.resolvingSymlinksInPath().path
        let eventLocators = indexedEvents.hasPrefix("/var/")
            ? [indexedEvents, "/private\(indexedEvents)"]
            : [indexedEvents]
        let eventStates = try writer.knownFileIndexStates(source: .copilot, locators: eventLocators)
        let state = try XCTUnwrap(
            eventLocators.lazy.compactMap { eventStates[$0] }.first
        )

        XCTAssertEqual(result.indexed, 1)
        XCTAssertEqual(try sessionIntValue("message_count", id: "copilot-capped"), 2)
        XCTAssertEqual(state.parseStatus, .terminal)
        XCTAssertEqual(state.failureKind, .messageLimitExceeded)
        XCTAssertEqual(state.sizeBytes, expectedIdentity.sizeBytes)
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

    /// R1/R2 P1 source-disable-reclassification-bypass: filtering only the
    /// adapter's declared source is insufficient because the Claude parser may
    /// reclassify its output as a derived source after parsing.
    func testIndexerHidesExistingRowWhenReclassifiedOutputSourceDisabled_repro() async throws {
        let locator = "/tmp/reclassified.jsonl"
        let initialAdapter = ParseCountingSessionAdapter(locators: [locator])
        let initial = try await writer.indexRecentSessions(adapters: [initialAdapter])
        XCTAssertEqual(initial.indexed, 1)
        XCTAssertEqual(try sessionValue("source", id: "reclassified"), SourceName.claudeCode.rawValue)
        XCTAssertNil(try sessionValue("hidden_at", id: "reclassified"))

        let reclassifiedAdapter = ParseCountingSessionAdapter(
            locators: [locator],
            outputSource: .lobsterai
        )
        let result = try await writer.indexRecentSessions(
            adapters: [reclassifiedAdapter],
            excludedSnapshotSources: [.lobsterai]
        )

        XCTAssertEqual(result.indexed, 0, "disabled reclassified output must not be indexed")
        XCTAssertEqual(
            reclassifiedAdapter.scanForIndexingCalls,
            1,
            "the post-parse classification must be observed"
        )
        XCTAssertEqual(
            try sessionValue("source", id: "reclassified"),
            SourceName.lobsterai.rawValue,
            "the stale row must move under the disabled output source"
        )
        XCTAssertNotNil(
            try sessionValue("hidden_at", id: "reclassified"),
            "a previously visible row must not bypass the disabled output source"
        )
    }

    func testExcludedSnapshotWithTerminalParseFailureDoesNotRecordFileState_repro() async throws {
        let locator = FileManager.default.temporaryDirectory
            .appendingPathComponent("excluded-terminal-\(UUID().uuidString).jsonl")
        try Data("{}".utf8).write(to: locator)
        defer { try? FileManager.default.removeItem(at: locator) }
        let adapter = ParseCountingSessionAdapter(
            locators: [locator.path],
            outputSource: .lobsterai,
            parseFailure: .messageLimitExceeded
        )

        let result = try await writer.indexRecentSessions(
            adapters: [adapter],
            excludedSnapshotSources: [.lobsterai]
        )

        XCTAssertEqual(result.indexed, 0)
        XCTAssertNil(
            try fileState(locator: locator.path),
            "a disabled output source must remain eligible for a real parse after it is re-enabled"
        )
    }

    /// Startup indexing skips every already-known locator, so it must not pay
    /// the cost of materializing full tail-merge snapshots that can never be
    /// consumed by `attemptTailIndexing` in that mode.
    func testStartupSkipKnownDoesNotLoadTailMergeSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skip-known-tail-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("session.jsonl")
        try writeClaudeLines(mergeSafeClaudeLines(), to: locator)
        let sink = TailSnapshotCountingSink()
        let adapter = CountingTailAdapter(projectsRoot: root.path)
        let indexer = SwiftIndexer(
            sink: sink,
            adapters: [adapter],
            skipKnownFileLocators: true
        )

        _ = try await indexer.indexAll()

        XCTAssertEqual(
            sink.knownTailMergeSnapshotCalls,
            0,
            "startup skip-known mode must not materialize unused tail snapshots"
        )
    }

    func testStartupKnownLocatorWithoutFileIndexStateReparses_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skip-known-missing-parse-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = root.appendingPathComponent("session.jsonl")
        try "{}\n".write(to: locator, atomically: true, encoding: .utf8)
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: locator.path)[.size] as? NSNumber
        ).int64Value
        let sink = MissingParseStateKnownLocatorSink(locator: locator.path, sizeBytes: size)
        let adapter = ParseCountingSessionAdapter(locators: [locator.path])
        let indexer = SwiftIndexer(
            sink: sink,
            adapters: [adapter],
            skipUnchangedFileLocators: true,
            skipKnownFileLocators: true
        )

        _ = try await indexer.indexAll()

        XCTAssertEqual(adapter.scanForIndexingCalls, 1, "a sessions row without file_index_state must heal through a real parse")
    }

    /// Startup callers need an adapter boundary where allocator pages can be
    /// reclaimed before the next source adds another parser workload.
    func testIndexerReportsEachCompletedAdapter() async throws {
        let completion = AdapterCompletionRecorder()
        let indexer = SwiftIndexer(
            sink: CollectingNoopSink(),
            adapters: [
                ParseCountingSessionAdapter(locators: ["/tmp/source-a.jsonl"]),
                ParseCountingSessionAdapter(locators: ["/tmp/source-b.jsonl"]),
            ],
            didFinishAdapter: { _ in completion.record() }
        )

        _ = try await indexer.indexAll()

        XCTAssertEqual(completion.count, 2)
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
            "/repo/proj/subagents/child.jsonl": .init(id: "subagent", agentRole: "subagent", messages: rich, messageCountOverride: 5),
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
            XCTAssertEqual(try beatCount("subagent"), 0, "adapter-stamped subagent skip must not persist work beats")
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
        // R8: durable content_fingerprint lets a user-led append merge without
        // a second full reparse while remaining parity-stable with full scan.
        XCTAssertEqual(adapter.scanTailForIndexingCalls, 1, "must still attempt the tail path first")
        XCTAssertEqual(
            adapter.scanForIndexingCalls,
            1,
            "append pass must merge via tail path, not full reparse"
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

    /// R184-4: tail `malformedJSON` must fall through to a full scan instead of
    /// being recorded as a terminal skip (same policy as FileIndexState).
    func testClaudeCodeTailMalformedJSONFallsThroughToFullParse_repro() async throws {
        let fixture = try makeClaudeFixture(name: "tail-malformed-fallback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeClaudeLines(mergeSafeClaudeLines(), to: fixture.locator)
        let adapter = CountingTailAdapter(projectsRoot: fixture.root.path)

        _ = try await writer.indexRecentSessions(adapters: [adapter])
        XCTAssertEqual(adapter.scanForIndexingCalls, 1)
        XCTAssertEqual(adapter.scanTailForIndexingCalls, 0)

        adapter.forcedTailFailure = .malformedJSON
        try appendText(tailClaudeLines().joined(separator: "\n") + "\n", to: fixture.locator)
        _ = try await writer.indexRecentSessions(adapters: [adapter])

        XCTAssertEqual(adapter.scanTailForIndexingCalls, 1, "must still attempt the tail path first")
        XCTAssertEqual(
            adapter.scanForIndexingCalls,
            2,
            "R184-4: malformedJSON tail must fall through to full parse"
        )
    }

    /// R184-4: tail and full-parse share one terminal classifier.
    func testTailTerminalPolicyDelegatesToFileIndexState_repro() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: macosRoot.appendingPathComponent("EngramCoreWrite/Indexing/SwiftIndexer.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private static func isTerminalTailFailure"))
        let end = try XCTUnwrap(
            source.range(of: "private static func isProvableSkip", options: [], range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("FileIndexState.isTerminalFailure"))
        XCTAssertFalse(body.contains("case .malformedJSON"))
        XCTAssertFalse(FileIndexState.isTerminalFailure(.malformedJSON))
        XCTAssertFalse(FileIndexState.isTerminalFailure(.invalidUtf8))
        XCTAssertFalse(FileIndexState.isTerminalFailure(.fileMissing))
        XCTAssertTrue(FileIndexState.isTerminalFailure(.noVisibleMessages))
    }

    /// R184-4: `noVisibleMessages` stays terminal on both tail and full paths.
    func testClaudeCodeTailNoVisibleMessagesStaysTerminal_repro() async throws {
        let fixture = try makeClaudeFixture(name: "tail-novisible-terminal")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeClaudeLines(mergeSafeClaudeLines(), to: fixture.locator)
        let adapter = CountingTailAdapter(projectsRoot: fixture.root.path)

        _ = try await writer.indexRecentSessions(adapters: [adapter])
        XCTAssertEqual(adapter.scanForIndexingCalls, 1)

        adapter.forcedTailFailure = .noVisibleMessages
        try appendText(tailClaudeLines().joined(separator: "\n") + "\n", to: fixture.locator)
        _ = try await writer.indexRecentSessions(adapters: [adapter])

        XCTAssertEqual(adapter.scanTailForIndexingCalls, 1)
        XCTAssertEqual(
            adapter.scanForIndexingCalls,
            1,
            "noVisibleMessages tail must stay terminal and skip full reparse"
        )
    }

    func testTailMergeCumulativeMessageLimitBecomesTerminal_repro() async throws {
        let fixture = try makeClaudeFixture(name: "tail-cumulative-limit")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeClaudeLines(mergeSafeClaudeLines(), to: fixture.locator)
        let adapter = CountingTailAdapter(projectsRoot: fixture.root.path)

        _ = try await writer.indexRecentSessions(adapters: [adapter])
        XCTAssertEqual(try sessionIntValue("message_count", id: "tail-session"), 6)

        try appendText("\n", to: fixture.locator)
        let appendedSize = Int64(try Data(contentsOf: fixture.locator).count)
        adapter.forcedTailResult = .success(
            IndexingTailScan(
                infoDelta: IndexingTailInfoDelta(
                    id: "tail-session",
                    source: .claudeCode,
                    endTime: "2026-08-21T00:00:00Z",
                    model: nil,
                    messageCount: 9_995,
                    userMessageCount: 9_995,
                    assistantMessageCount: 0,
                    toolMessageCount: 0,
                    systemMessageCount: 0,
                    firstVisibleRole: .user
                ),
                messages: [NormalizedMessage(role: .user, content: "overflow")],
                parsedOffset: appendedSize,
                boundaryHash: "overflow-boundary"
            )
        )

        let result = try await writer.indexRecentSessions(adapters: [adapter])
        let state = try XCTUnwrap(fileState(locator: indexedLocator(fixture.locator)))

        XCTAssertEqual(result.indexed, 0)
        XCTAssertEqual(try sessionIntValue("message_count", id: "tail-session"), 6)
        XCTAssertEqual(state.parseStatus, .terminal)
        XCTAssertEqual(state.failureKind, .messageLimitExceeded)
        XCTAssertEqual(state.lastError, ParserFailure.messageLimitExceeded.rawValue)
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

    /// R8 repro: Codex product path must merge a user-led append via
    /// `mergeTailSnapshot` (not always nil) and stay parity-stable with a full reindex.
    func testCodexTailMergeMatchesFullReindex_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-tail-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("rollout-codex-tail-merge.jsonl")
        let baseLines: [[String: Any]] = [
            [
                "timestamp": "2026-06-01T10:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "codex-tail-merge-1",
                    "timestamp": "2026-06-01T10:00:00.000Z",
                    "cwd": "/tmp/codex-tail-merge",
                    "originator": "codex",
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:01.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "First codex turn"]],
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:02.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "First reply"]],
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:03.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "Second codex turn"]],
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:04.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "Second reply"]],
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:05.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "Third codex turn"]],
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:06.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "Third reply"]],
                ],
            ],
        ]
        try (baseLines.map { jsonLine($0) }.joined(separator: "\n") + "\n")
            .write(to: locator, atomically: true, encoding: .utf8)

        let adapter = CountingCodexTailAdapter(sessionsRoot: root.path)
        let initial = try await writer.indexRecentSessions(adapters: [adapter])
        XCTAssertEqual(initial.indexed, 1)
        try await drainFtsJobs(writer, adapter: adapter)
        XCTAssertEqual(adapter.scanForIndexingCalls, 1)
        XCTAssertEqual(adapter.scanTailForIndexingCalls, 0)
        let fingerprint = try sessionValue("content_fingerprint", id: "codex-tail-merge-1")
        XCTAssertNotNil(fingerprint)
        XCTAssertFalse(fingerprint?.isEmpty ?? true)

        let tailLines: [[String: Any]] = [
            [
                "timestamp": "2026-06-01T10:00:07.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "Appended codex tailonlysearchtoken"]],
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:08.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "Tail merged reply"]],
                ],
            ],
        ]
        let handle = try FileHandle(forWritingTo: locator)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((tailLines.map { jsonLine($0) }.joined(separator: "\n") + "\n").utf8))

        _ = try await writer.indexRecentSessions(adapters: [adapter])
        try await drainFtsJobs(writer, adapter: adapter)
        XCTAssertEqual(adapter.scanTailForIndexingCalls, 1, "must attempt Codex tail path")
        XCTAssertEqual(
            adapter.scanForIndexingCalls,
            1,
            "Codex user-led append must merge without full reparse (R8)"
        )
        XCTAssertEqual(try sessionIntValue("message_count", id: "codex-tail-merge-1"), 8)
        XCTAssertEqual(try ftsHits(writer, "tailonlysearchtoken"), 1)

        let fullDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-tail-full-\(UUID().uuidString).sqlite")
        let fullWriter = try EngramDatabaseWriter(path: fullDB.path)
        defer { try? FileManager.default.removeItem(at: fullDB) }
        try fullWriter.migrate()
        _ = try await fullWriter.indexRecentSessions(adapters: [CodexAdapter(sessionsRoot: root.path)])
        try await drainFtsJobs(fullWriter, adapter: CodexAdapter(sessionsRoot: root.path))

        // session_costs.cost_usd can be NULL vs 0.0 when no token events exist; the
        // tail path does not invent usage. Compare counts/tools/beats/fingerprint.
        for table in stableParityTables
            where table.name != "session_index_jobs" && table.name != "session_costs"
        {
            XCTAssertEqual(
                try stableRows(writer, table.sql),
                try stableRows(fullWriter, table.sql),
                table.name
            )
        }
        XCTAssertEqual(try sessionIntValue("message_count", id: "codex-tail-merge-1"), 8)
        XCTAssertEqual(
            try sessionValue("content_fingerprint", id: "codex-tail-merge-1"),
            try fullWriter.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT content_fingerprint FROM sessions WHERE id = ?",
                    arguments: ["codex-tail-merge-1"]
                )
            }
        )
        XCTAssertEqual(
            try sessionValue("snapshot_hash", id: "codex-tail-merge-1"),
            try fullWriter.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT snapshot_hash FROM sessions WHERE id = ?",
                    arguments: ["codex-tail-merge-1"]
                )
            }
        )
    }

    func testOpenCodeBoundedReadUsesProducedMessageCap_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-bounded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        let queue = try DatabaseQueue(path: dbPath)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE session (
                    id TEXT PRIMARY KEY, directory TEXT, title TEXT,
                    time_created INTEGER, time_updated INTEGER, time_archived INTEGER
                );
                CREATE TABLE message (
                    id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT
                );
                CREATE TABLE part (
                    id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT
                );
                INSERT INTO session VALUES ('bounded', '/tmp/opencode', 'Bounded', 1, 5, NULL);
                """)
            let rows: [(String, String, String)] = [
                ("m0", #"{"role":"user"}"#, #"{"type":"text","text":"   "}"#),
                ("m1", #"{"role":"user"}"#, #"{"type":"text","text":"one"}"#),
                ("m2", #"{"role":"assistant"}"#, #"{"type":"tool","text":"ignored"}"#),
                ("m3", #"{"role":"assistant"}"#, #"{"type":"text","text":"two"}"#),
                ("m4", #"{"role":"user"}"#, #"{"type":"text","text":"three"}"#),
            ]
            for (index, row) in rows.enumerated() {
                try db.execute(
                    sql: "INSERT INTO message VALUES (?, 'bounded', ?, ?)",
                    arguments: [row.0, index + 1, row.1]
                )
                try db.execute(
                    sql: "INSERT INTO part VALUES (?, ?, ?, ?)",
                    arguments: ["p\(index)", row.0, index + 1, row.2]
                )
            }
            try db.execute(
                sql: "INSERT INTO part VALUES ('p1b', 'm1', 2, ?)",
                arguments: [#"{"type":"text","text":"one-b"}"#]
            )
        }

        let adapter = OpenCodeAdapter(dbPath: dbPath, limits: ParserLimits(maxMessages: 2))
        let locator = "\(dbPath)::bounded"
        let firstPage = try await adapter.streamMessagesWithMetadata(
            locator: locator,
            options: StreamMessagesOptions(offset: 0, limit: 1)
        )
        var firstMessages: [NormalizedMessage] = []
        for try await message in firstPage.messages { firstMessages.append(message) }
        XCTAssertEqual(firstMessages.map(\.content), ["one\none-b"])
        XCTAssertNil(firstPage.truncatedAt)

        let terminalPage = try await adapter.streamMessagesWithMetadata(
            locator: locator,
            options: StreamMessagesOptions(offset: 1, limit: 1)
        )
        var terminalMessages: [NormalizedMessage] = []
        for try await message in terminalPage.messages { terminalMessages.append(message) }
        XCTAssertEqual(terminalMessages.map(\.content), ["two"])
        XCTAssertEqual(terminalPage.truncatedAt, 2)

        do {
            _ = try await adapter.streamMessages(locator: locator, options: StreamMessagesOptions())
            XCTFail("unwindowed OpenCode reads must fail instead of returning a capped prefix")
        } catch let failure as ParserFailure {
            XCTAssertEqual(failure, .messageLimitExceeded)
        }
    }

    func testOpenCodeSQLReadIsPagedInsteadOfMaterializingAllJoinedRows_repro() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/EngramCore/Adapters/Sources/OpenCodeAdapter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private static func messages(\n"))
        let end = try XCTUnwrap(source.range(of: "private static func splitVirtualLocator", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(
            body.contains("LIMIT \\(pageSize) OFFSET \\(offset)"),
            "joined SQLite rows must be fetched in bounded pages"
        )
        XCTAssertTrue(body.contains("hasMoreMessages"), "the extra produced message must drive truncation metadata")
    }

    func testCopilotIgnoresEmptyEventShellsForDiscoveryAndCounts_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-empty-shells-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let emptySession = root.appendingPathComponent("empty", isDirectory: true)
        let emptyCheckpoints = emptySession.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyCheckpoints, withIntermediateDirectories: true)
        try #"{"type":"user.message","data":{"content":"   "}}"#.appending("\n")
            .write(to: emptySession.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        try "| 1 | Restored | 1.md |\n"
            .write(to: emptyCheckpoints.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)

        let validSession = root.appendingPathComponent("valid", isDirectory: true)
        try FileManager.default.createDirectory(at: validSession, withIntermediateDirectories: true)
        let validEvents = validSession.appendingPathComponent("events.jsonl")
        try [
            #"{"type":"user.message","timestamp":"2026-01-01T00:00:00Z","data":{"content":"real"}}"#,
            #"{"type":"assistant.message","timestamp":"2026-01-01T00:00:01Z","data":{"content":"\n\t"}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: validEvents, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(sessionRoot: root.path)
        let locators = try await adapter.listSessionLocators()
        XCTAssertTrue(locators.contains { $0.hasSuffix("/empty/checkpoints/index.md") })
        XCTAssertTrue(locators.contains { $0.hasSuffix("/valid/events.jsonl") })
        guard case .success(let info) = try await adapter.parseSessionInfo(locator: validEvents.path) else {
            return XCTFail("valid event transcript must parse")
        }
        XCTAssertEqual(info.messageCount, 1)
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 0)
    }

    func testCopilotOversizedEventsStillWinDiscoveryAndSurfaceParserFailure_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-oversized-discovery-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("session", isDirectory: true)
        let checkpoints = session.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = session.appendingPathComponent("events.jsonl")
        try #"{"type":"user.message","data":{"content":""#
            .appending(String(repeating: "x", count: 300))
            .appending(#""}}"#)
            .appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)
        try "| 1 | Fallback | 1.md |\n"
            .write(to: checkpoints.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(
            sessionRoot: root.path,
            limits: ParserLimits(maxFileBytes: 64, maxLineBytes: 1_024, maxMessages: 10)
        )
        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(locators.count, 1)
        XCTAssertTrue(locators.first?.hasSuffix("/session/events.jsonl") == true)
        guard case .failure(let failure) = try await adapter.parseSessionInfo(locator: events.path) else {
            return XCTFail("oversized events must remain selected and report their failure")
        }
        XCTAssertEqual(failure, .fileTooLarge)
    }

    func testCopilotCheckpointCapChecksBeforeBodiesAndScanKeepsPrefix_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-checkpoint-cap-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("session", isDirectory: true)
        let checkpoints = session.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "id: copilot-checkpoint-cap\ncwd: /tmp/copilot\n"
            .write(to: session.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let index = checkpoints.appendingPathComponent("index.md")
        try (1...3).map { "| \($0) | Checkpoint \($0) | \($0).md |" }
            .joined(separator: "\n").appending("\n")
            .write(to: index, atomically: true, encoding: .utf8)
        for number in 1...3 {
            try "body \(number)".write(
                to: checkpoints.appendingPathComponent("\(number).md"),
                atomically: true,
                encoding: .utf8
            )
        }

        let parseRecorder = AdapterCompletionRecorder()
        let parseAdapter = CopilotAdapter(
            sessionRoot: root.path,
            limits: ParserLimits(maxMessages: 2),
            testHooks: CopilotAdapterTestHooks(beforeCheckpointBodyIdentityValidation: { _ in
                parseRecorder.record()
            })
        )
        guard case .failure(let parseFailure) = try await parseAdapter.parseSessionInfo(locator: index.path) else {
            return XCTFail("checkpoint info beyond cap must fail closed")
        }
        XCTAssertEqual(parseFailure, .messageLimitExceeded)
        XCTAssertEqual(parseRecorder.count, 0, "info parsing must reject the index before opening bodies")

        let scanRecorder = AdapterCompletionRecorder()
        let scanAdapter = CopilotAdapter(
            sessionRoot: root.path,
            limits: ParserLimits(maxMessages: 2),
            testHooks: CopilotAdapterTestHooks(beforeCheckpointBodyIdentityValidation: { _ in
                scanRecorder.record()
            })
        )
        guard case .success(let scan) = try await scanAdapter.scanForIndexing(locator: index.path) else {
            return XCTFail("checkpoint indexing must retain its bounded prefix")
        }
        XCTAssertEqual(scan.info.messageCount, 2)
        XCTAssertEqual(scan.messages.map(\.content), [
            "Checkpoint 1: Checkpoint 1\n\nbody 1",
            "Checkpoint 2: Checkpoint 2\n\nbody 2",
        ])
        XCTAssertEqual(scan.parseFailure, .messageLimitExceeded)
        XCTAssertEqual(scanRecorder.count, 2, "scan must open at most the visible prefix bodies")
    }

    func testCopilotCheckpointBodyReadIsBoundedByUTF8Bytes_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-checkpoint-bytes-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("session", isDirectory: true)
        let checkpoints = session.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = checkpoints.appendingPathComponent("index.md")
        try "| 1 | Unicode | 1.md |\n".write(to: index, atomically: true, encoding: .utf8)
        try String(repeating: "你", count: 2_000)
            .write(to: checkpoints.appendingPathComponent("1.md"), atomically: true, encoding: .utf8)

        let result = try await CopilotAdapter(sessionRoot: root.path).streamMessagesWithMetadata(
            locator: index.path,
            options: StreamMessagesOptions()
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }
        let content = try XCTUnwrap(messages.first?.content)
        let body = try XCTUnwrap(content.components(separatedBy: "\n\n").last)
        XCTAssertLessThanOrEqual(Data(body.utf8).count, 4_000)
    }

    func testKimiKeepsContextPrefixWhenFirstWireLineIsOversized_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-wire-prefix-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("workspace/kimi-wire-prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = session.appendingPathComponent("context.jsonl")
        try [
            #"{"role":"user","content":"keep me"}"#,
            #"{"role":"assistant","content":"kept"}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: context, atomically: true, encoding: .utf8)
        try #"{"padding":""#.appending(String(repeating: "x", count: 300)).appending(#""}"#).appending("\n")
            .write(to: session.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)

        let adapter = KimiAdapter(
            sessionsRoot: root.path,
            kimiJsonPath: root.appendingPathComponent("kimi.json").path,
            limits: ParserLimits(maxLineBytes: 64)
        )
        guard case .success(let info) = try await adapter.parseSessionInfo(locator: context.path) else {
            return XCTFail("valid context must not be discarded by auxiliary wire failure")
        }
        XCTAssertEqual(info.messageCount, 2)
        guard case .success(let scan) = try await adapter.scanForIndexing(locator: context.path) else {
            return XCTFail("indexing must retain the valid context prefix")
        }
        XCTAssertEqual(scan.messages.map(\.content), ["keep me", "kept"])
        XCTAssertEqual(scan.parseFailure, .lineTooLarge)
    }

    func testKimiCompositeIdentitySkipsUnchangedAndReparsesKimiJSONChanges_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-identity-skip-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("workspace/kimi-skip", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = session.appendingPathComponent("context.jsonl")
        try [
            #"{"role":"user","content":"question"}"#,
            #"{"role":"assistant","content":"answer"}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: context, atomically: true, encoding: .utf8)
        let kimiJSON = root.appendingPathComponent("kimi.json")
        func writeKimiJSON(path: String) throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "work_dirs": [["path": path, "last_session_id": "kimi-skip"]],
            ])
            try data.write(to: kimiJSON, options: .atomic)
        }
        try writeKimiJSON(path: "/repo-one")

        let adapter = CountingKimiAdapter(KimiAdapter(sessionsRoot: root.path, kimiJsonPath: kimiJSON.path))
        _ = try await writer.indexRecentSessions(adapters: [adapter])
        XCTAssertEqual(adapter.scanForIndexingCalls, 1)
        XCTAssertEqual(try sessionValue("cwd", id: "kimi-skip"), "/repo-one")

        _ = try await writer.indexRecentSessions(adapters: [adapter])
        XCTAssertEqual(adapter.scanForIndexingCalls, 1, "unchanged composite identity must skip")

        try writeKimiJSON(path: "/repo-two-with-a-different-size")
        _ = try await writer.indexRecentSessions(adapters: [adapter])
        XCTAssertEqual(adapter.scanForIndexingCalls, 2, "kimi.json is part of the composite identity")
        XCTAssertEqual(try sessionValue("cwd", id: "kimi-skip"), "/repo-two-with-a-different-size")
    }

    func testQwenUntimestampedConversationUsesFileModificationTime_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-mtime-\(UUID().uuidString)", isDirectory: true)
        let chats = root.appendingPathComponent("project/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = chats.appendingPathComponent("session.jsonl")
        try #"{"type":"user","sessionId":"qwen-mtime","cwd":"/tmp/qwen","message":{"role":"user","parts":[{"text":"hello"}]}}"#
            .appending("\n").write(to: file, atomically: true, encoding: .utf8)
        let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: file.path)

        let adapter = QwenAdapter(projectsRoot: root.path)
        guard case .success(let info) = try await adapter.parseSessionInfo(locator: file.path) else {
            return XCTFail("untimestamped Qwen conversation must parse")
        }
        XCTAssertEqual(info.startTime, Phase4AdapterSupport.isoFromSeconds(modificationDate.timeIntervalSince1970))
    }

    func testQoderScanRestatFailurePreservesNonemptyPrefix_repro() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/EngramCore/Adapters/Sources/QoderAdapter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func scanForIndexing(locator:"))
        let end = try XCTUnwrap(source.range(of: "func streamMessages(", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(body.contains("do {\n                after = try limits.fileIdentity(for: url)"))
        XCTAssertTrue(body.contains("parseFailure: .fileModifiedDuringParse"))
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
                       agent_role, parent_session_id, link_source, content_fingerprint
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

private final class CountingKimiAdapter: SessionAdapter, ModificationFilteredSessionAdapter, @unchecked Sendable {
    let source: SourceName = .kimi
    private let inner: KimiAdapter
    private let lock = NSLock()
    private var recordedScanForIndexingCalls = 0

    var scanForIndexingCalls: Int { lock.withLock { recordedScanForIndexingCalls } }

    init(_ inner: KimiAdapter) {
        self.inner = inner
    }

    func detect() async -> Bool { await inner.detect() }
    func listSessionLocators() async throws -> [String] { try await inner.listSessionLocators() }
    func listSessionLocators(modifiedSince: Date, fileManager: FileManager) async throws -> [String] {
        try await inner.listSessionLocators(modifiedSince: modifiedSince, fileManager: fileManager)
    }
    func indexingInputIdentity(locator: String) -> IndexingInputIdentity? {
        inner.indexingInputIdentity(locator: locator)
    }
    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        try await inner.parseSessionInfo(locator: locator)
    }
    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        lock.withLock { recordedScanForIndexingCalls += 1 }
        return try await inner.scanForIndexing(locator: locator)
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
    func isAccessible(locator: String) async -> Bool { await inner.isAccessible(locator: locator) }
}

/// Minimal write sink for `collectSnapshots`, which never calls `upsertBatch`.
private struct CollectingNoopSink: IndexingWriteSink {
    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        SessionBatchUpsertResult(reason: reason, results: [])
    }
}

private final class TailSnapshotCountingSink: IndexingWriteSink {
    private(set) var knownTailMergeSnapshotCalls = 0

    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        SessionBatchUpsertResult(
            reason: reason,
            results: snapshots.map {
                SessionBatchItemResult(sessionId: $0.id, action: .merge, enqueuedJobs: [])
            }
        )
    }

    func knownTailMergeSnapshots(
        source: SourceName,
        locators: [String]
    ) throws -> [String: AuthoritativeSessionSnapshot] {
        knownTailMergeSnapshotCalls += 1
        return [:]
    }
}

private struct MissingParseStateKnownLocatorSink: IndexingWriteSink {
    let locator: String
    let sizeBytes: Int64

    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        SessionBatchUpsertResult(
            reason: reason,
            results: snapshots.map {
                SessionBatchItemResult(sessionId: $0.id, action: .merge, enqueuedJobs: [])
            }
        )
    }

    func knownIndexedFileStates(
        source: SourceName,
        locators: [String]
    ) throws -> [String: KnownIndexedFileState] {
        [locator: KnownIndexedFileState(sizeBytes: sizeBytes, indexedAt: "2999-01-01T00:00:00Z")]
    }
}

// MARK: - Test adapters

private final class CountingCodexTailAdapter: TailIndexingSessionAdapter {
    let source: SourceName = .codex
    private let inner: CodexAdapter
    private(set) var scanForIndexingCalls = 0
    private(set) var scanTailForIndexingCalls = 0

    init(sessionsRoot: String) {
        self.inner = CodexAdapter(sessionsRoot: sessionsRoot)
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

private final class CountingTailAdapter: TailIndexingSessionAdapter {
    let source: SourceName = .claudeCode
    private let inner: ClaudeCodeAdapter
    private(set) var scanForIndexingCalls = 0
    private(set) var scanTailForIndexingCalls = 0
    var forcedTailFailure: ParserFailure?
    var forcedTailResult: IndexingTailScanResult?

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
        if let forcedTailResult {
            return forcedTailResult
        }
        if let forcedTailFailure {
            return .failure(forcedTailFailure)
        }
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
    private let outputSource: SourceName
    private let parseFailure: ParserFailure?
    private(set) var parseSessionInfoCalls = 0
    private(set) var streamMessagesCalls = 0
    private(set) var scanForIndexingCalls = 0

    init(
        locators: [String],
        outputSource: SourceName = .claudeCode,
        parseFailure: ParserFailure? = nil
    ) {
        self.locators = locators
        self.outputSource = outputSource
        self.parseFailure = parseFailure
    }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { locators }
    func isAccessible(locator: String) async -> Bool { true }

    private func info(for locator: String) -> NormalizedSessionInfo {
        NormalizedSessionInfo(
            id: URL(fileURLWithPath: locator).deletingPathExtension().lastPathComponent,
            source: outputSource,
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
        return .success(
            IndexingScan(
                info: info(for: locator),
                messages: messages,
                parseFailure: parseFailure
            )
        )
    }
}

private final class AdapterCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int { lock.withLock { recordedCount } }

    func record() {
        lock.withLock { recordedCount += 1 }
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
