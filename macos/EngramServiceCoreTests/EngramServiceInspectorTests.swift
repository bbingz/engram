import XCTest
import GRDB
@testable import EngramServiceCore

final class EngramServiceInspectorTests: XCTestCase {
    func testMissingSessionThrowsInvalidRequest() async throws {
        let path = try makeInspectorDatabase()
        let provider = SQLiteEngramServiceReadProvider(databasePath: path)
        do {
            _ = try await provider.inspectSession(EngramServiceSessionInspectorRequest(id: "ghost"))
            XCTFail("Expected invalidRequest for missing session")
        } catch let error as EngramServiceError {
            XCTAssertEqual(error, .invalidRequest(message: "Session not found: ghost"))
        }
    }

    func testParentSessionDTOSmokeMatchesPhase0Invariants() async throws {
        let path = try makeInspectorDatabase()
        try seedInspectorParent(at: path)
        let provider = SQLiteEngramServiceReadProvider(databasePath: path)

        let dto = try await provider.inspectSession(
            EngramServiceSessionInspectorRequest(id: "mcp-inspector-parent")
        )

        XCTAssertEqual(dto.session.id, "mcp-inspector-parent")
        XCTAssertEqual(dto.session.source, "codex")
        XCTAssertEqual(dto.session.messageCount, 8)
        XCTAssertEqual(dto.session.tier, "normal")
        XCTAssertEqual(dto.summaries.displayTitle, "Inspector golden parent")
        XCTAssertEqual(dto.summaries.storedSummary, "Inspector fixture parent session")
        XCTAssertEqual(dto.summaries.summaryMessageCount, 8)
        XCTAssertEqual(dto.status.label, "done")
        XCTAssertEqual(dto.status.confidence, "high")
        XCTAssertEqual(dto.status.basisTags, ["has_end_time"])
        XCTAssertEqual(dto.provenance.cost, "database")
        XCTAssertEqual(dto.provenance.transcript, "local_file")
    }

    func testAuditRowIsVisibleButLlmSummaryStaysAbsent() async throws {
        let path = try makeInspectorDatabase()
        try seedInspectorParent(at: path)
        let provider = SQLiteEngramServiceReadProvider(databasePath: path)

        let dto = try await provider.inspectSession(
            EngramServiceSessionInspectorRequest(id: "mcp-inspector-parent")
        )

        // Audit row is reflected in correlation metadata.
        XCTAssertEqual(dto.llm.auditRecordCount, 1)
        XCTAssertEqual(dto.llm.callers, ["summary"])
        XCTAssertEqual(dto.llm.trigger, "manual")
        XCTAssertEqual(dto.llm.resolvedSummaryConfig?.preset, "standard")
        XCTAssertEqual(dto.llm.resolvedSummaryConfig?.maxTokens, 200)

        // Phase 0 invariant: llmSummary stays absent + provenance "unknown",
        // even though an audit record exists.
        XCTAssertNil(dto.summaries.llmSummary)
        XCTAssertEqual(dto.summaries.provenance.llmSummary, "unknown")
    }

    func testChildRollupSeparatesParentAndChildCost() async throws {
        let path = try makeInspectorDatabase()
        try seedInspectorParent(at: path)
        try seedInspectorChild(at: path)
        let provider = SQLiteEngramServiceReadProvider(databasePath: path)

        let dto = try await provider.inspectSession(
            EngramServiceSessionInspectorRequest(id: "mcp-inspector-parent")
        )

        // Parent's own cost stays parent-scoped.
        XCTAssertEqual(dto.cost.inputTokens, 1000)
        XCTAssertEqual(dto.cost.outputTokens, 500)
        XCTAssertEqual(dto.cost.estimatedCostUsd, 0.5)
        XCTAssertEqual(dto.cost.source, "engram_pricing")

        // Child rollup is reported separately and excludes parent.
        XCTAssertEqual(dto.agentGraph.childCount, 1)
        XCTAssertEqual(dto.agentGraph.suggestedChildCount, 1)
        XCTAssertEqual(dto.agentGraph.childRollup?.sources["codex"], 1)
        XCTAssertEqual(dto.agentGraph.childRollup?.tokenTotal, 200)
        XCTAssertEqual(dto.agentGraph.childRollup?.estimatedCostUsd, 0.125)
    }

    func testDefaultResumeIsUnsupportedWithoutCommandOrArgs() async throws {
        let path = try makeInspectorDatabase()
        try seedInspectorParent(at: path)
        let provider = SQLiteEngramServiceReadProvider(databasePath: path)

        let dto = try await provider.inspectSession(
            EngramServiceSessionInspectorRequest(id: "mcp-inspector-parent")
        )

        XCTAssertEqual(dto.resume.capability, "unsupported")
        XCTAssertEqual(dto.resume.tool, "codex")
        XCTAssertEqual(dto.resume.evidence, "fallback")
        XCTAssertNil(dto.resume.command)
        XCTAssertNil(dto.resume.args)
        XCTAssertEqual(dto.resume.warning, "codex command path not resolved (no resolver provided)")
    }

    func testDecodesContractGoldenFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/mcp-golden/session_inspector.fixture.json")
        let envelope = try JSONDecoder().decode(MCPGoldenEnvelope.self, from: Data(contentsOf: url))
        let inner = try XCTUnwrap(envelope.content.first?.text)
        let dto = try JSONDecoder().decode(EngramServiceSessionInspector.self, from: Data(inner.utf8))
        XCTAssertEqual(dto.session.id, "mcp-inspector-parent")
        XCTAssertEqual(dto.summaries.provenance.llmSummary, "unknown")
        XCTAssertEqual(dto.resume.capability, "unsupported")
        XCTAssertNil(dto.resume.command)
    }
}

private struct MCPGoldenEnvelope: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String
    }
    let content: [Block]
}

private func makeInspectorDatabase() throws -> String {
    let runtime = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("engram-inspector-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(
        at: runtime,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let path = runtime.appendingPathComponent("inspector.sqlite").path
    let queue = try DatabaseQueue(path: path)
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
              local_readable_path TEXT,
              custom_name TEXT
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
            CREATE TABLE ai_audit_log (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts TEXT NOT NULL,
              caller TEXT NOT NULL,
              operation TEXT NOT NULL DEFAULT '',
              session_id TEXT,
              error TEXT,
              meta TEXT
            );
        """)
    }
    return path
}

private func seedInspectorParent(at path: String) throws {
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(sql: """
            INSERT INTO sessions (
              id, source, start_time, end_time, cwd, project, model, message_count,
              file_path, size_bytes, indexed_at, summary, summary_message_count,
              tier, generated_title
            ) VALUES (
              'mcp-inspector-parent', 'codex',
              '2026-05-07T08:00:00.000Z', '2026-05-07T08:30:00.000Z',
              '/Users/test/work/engram', 'engram', 'gpt-5.4', 8,
              '/Users/test/work/engram/.fixtures/mcp-inspector-parent.jsonl', 1024,
              '2026-05-07T08:30:01.000Z',
              'Inspector fixture parent session', 8,
              'normal', 'Inspector golden parent'
            );
            INSERT INTO session_costs (
              session_id, model, input_tokens, output_tokens,
              cache_read_tokens, cache_creation_tokens, cost_usd
            ) VALUES (
              'mcp-inspector-parent', 'gpt-5.4', 1000, 500, 0, 0, 0.5
            );
            INSERT INTO ai_audit_log (
              ts, caller, operation, session_id, meta
            ) VALUES (
              '2026-05-07T08:31:00.000', 'summary', 'summarize',
              'mcp-inspector-parent',
              '{"trigger":"manual","resolvedConfig":{"preset":"standard","maxTokens":200,"temperature":0.3,"sampleFirst":20,"sampleLast":30,"truncateChars":500}}'
            );
        """)
    }
}

private func seedInspectorChild(at path: String) throws {
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(sql: """
            INSERT INTO sessions (
              id, source, start_time, end_time, cwd, project, message_count,
              file_path, size_bytes, indexed_at, parent_session_id
            ) VALUES (
              'mcp-inspector-child-1', 'codex',
              '2026-05-07T08:05:00.000Z', '2026-05-07T08:10:00.000Z',
              '/Users/test/work/engram', 'engram', 4,
              '/Users/test/work/engram/.fixtures/mcp-inspector-child-1.jsonl',
              512, '2026-05-07T08:10:01.000Z',
              'mcp-inspector-parent'
            );
            INSERT INTO session_costs (
              session_id, model, input_tokens, output_tokens,
              cache_read_tokens, cache_creation_tokens, cost_usd
            ) VALUES (
              'mcp-inspector-child-1', 'gpt-5.4', 150, 50, 0, 0, 0.125
            );
            INSERT INTO sessions (
              id, source, start_time, cwd, project, message_count,
              file_path, size_bytes, indexed_at, suggested_parent_id
            ) VALUES (
              'mcp-inspector-suggested-1', 'codex',
              '2026-05-07T08:15:00.000Z',
              '/Users/test/work/engram', 'engram', 2,
              '/Users/test/work/engram/.fixtures/mcp-inspector-suggested-1.jsonl',
              256, '2026-05-07T08:15:01.000Z',
              'mcp-inspector-parent'
            );
        """)
    }
}
