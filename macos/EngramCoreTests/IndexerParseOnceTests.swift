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
