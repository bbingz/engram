import XCTest
import GRDB
import Foundation
import EngramCoreRead
import EngramCoreWrite
@testable import EngramServiceCore

/// Wave 8A lane 1A service regressions: H07 model equality, M06 degrade
/// reasons, M09 full-corpus constant-memory top-K (no recency eligibility).
final class SemanticSearchIntegrityTests: XCTestCase {
    // MARK: - H07

    func testSemanticSearchRejectsSameDimensionDifferentModelWithoutEmbedding() async throws {
        let paths = try makePaths()
        try seedBaseSessions(at: paths.database.path)
        try seedSemanticCorpus(
            at: paths.database.path,
            model: "model-a",
            sessions: [
                ("exact-old", "2020-01-01T00:00:00Z", [1, 0, 0], "exact match about vector memory"),
            ]
        )

        let embedCalls = EmbedCallCounter()
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "model-b",
                "ENGRAM_EMBEDDING_DIM": "3",
                "ENGRAM_EMBEDDING_BASE_URL": "https://api.example.com/v1",
            ],
            embeddingProviderFactory: { _ in
                CountingEmbeddingProvider(counter: embedCalls) { _ in [1, 0, 0] }
            }
        )

        let response = try await provider.search(
            EngramServiceSearchRequest(query: "vector memory", mode: "semantic", limit: 10)
        )

        XCTAssertEqual(response.searchModes, ["keyword"])
        let warning = try XCTUnwrap(response.warning)
        XCTAssertTrue(
            warning.localizedCaseInsensitiveContains("model"),
            "warning must name model mismatch: \(warning)"
        )
        XCTAssertTrue(
            warning.localizedCaseInsensitiveContains("mismatch")
                || warning.localizedCaseInsensitiveContains("model-b")
                || warning.localizedCaseInsensitiveContains("model-a"),
            "warning must identify mismatch: \(warning)"
        )
        let embedCallCount = await embedCalls.count()
        XCTAssertEqual(
            embedCallCount,
            0,
            "H07: must not generate a query embedding on model mismatch"
        )
        XCTAssertFalse(
            response.items.contains { $0.matchType == "semantic" },
            "must not perform cosine ranking under model mismatch"
        )
    }

    // MARK: - M06

    func testSemanticDegradeWarningNamesProviderUnavailable() async throws {
        let paths = try makePaths()
        try seedBaseSessions(at: paths.database.path)
        try seedSemanticCorpus(
            at: paths.database.path,
            model: "probe",
            sessions: [("s2", "2026-06-01T00:00:00Z", [1, 0, 0], "semantic recall chunk")]
        )

        // No embedding env → provider unavailable.
        let provider = try SQLiteEngramServiceReadProvider(databasePath: paths.database.path)
        let response = try await provider.search(
            EngramServiceSearchRequest(query: "semantic recall", mode: "semantic", limit: 10)
        )
        XCTAssertEqual(response.searchModes, ["keyword"])
        let warning = try XCTUnwrap(response.warning)
        XCTAssertTrue(
            warning.localizedCaseInsensitiveContains("provider")
                || warning.localizedCaseInsensitiveContains("not configured"),
            "expected provider-unavailable wording, got: \(warning)"
        )
        XCTAssertFalse(
            warning.localizedCaseInsensitiveContains("breaker"),
            "must not mislabel as breaker: \(warning)"
        )
    }

    func testSemanticDegradeWarningNamesCorpusMissing() async throws {
        let paths = try makePaths()
        try seedBaseSessions(at: paths.database.path)
        // Sessions exist, but no semantic_chunks / embedding_meta.

        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
            ],
            embeddingProviderFactory: { _ in
                StaticIntegrityEmbeddingProvider { _ in [1, 0, 0] }
            }
        )
        let response = try await provider.search(
            EngramServiceSearchRequest(query: "hello world", mode: "semantic", limit: 10)
        )
        XCTAssertEqual(response.searchModes, ["keyword"])
        let warning = try XCTUnwrap(response.warning)
        XCTAssertTrue(
            warning.localizedCaseInsensitiveContains("corpus")
                || warning.localizedCaseInsensitiveContains("embedding")
                && warning.localizedCaseInsensitiveContains("missing"),
            "expected corpus-missing wording, got: \(warning)"
        )
    }

    func testSemanticDegradeWarningNamesBreakerOpenWithoutCallingInnerProvider() async throws {
        let paths = try makePaths()
        try seedBaseSessions(at: paths.database.path)
        try seedSemanticCorpus(
            at: paths.database.path,
            model: "probe",
            sessions: [("s2", "2026-06-01T00:00:00Z", [1, 0, 0], "semantic recall chunk")]
        )

        let embedCalls = EmbedCallCounter()
        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
            ],
            embeddingProviderFactory: { _ in
                CountingEmbeddingProvider(counter: embedCalls) { _ in
                    throw EmbeddingError.circuitOpen
                }
            }
        )
        let response = try await provider.search(
            EngramServiceSearchRequest(query: "semantic recall", mode: "semantic", limit: 10)
        )
        XCTAssertEqual(response.searchModes, ["keyword"])
        let warning = try XCTUnwrap(response.warning)
        XCTAssertTrue(
            warning.localizedCaseInsensitiveContains("breaker"),
            "expected breaker-open wording, got: \(warning)"
        )
        XCTAssertFalse(
            warning.localizedCaseInsensitiveContains("No embedding provider")
                || warning == "Semantic search is unavailable in the local service; returning keyword results only.",
            "must not use one-size-fits-all warning: \(warning)"
        )
        // Factory was invoked (guarded provider path), but the throw is circuitOpen.
        let breakerEmbedCalls = await embedCalls.count()
        XCTAssertEqual(breakerEmbedCalls, 1)
    }

    // MARK: - M09

    func testFullCorpusSemanticTopKPrefersOldExactMatchOutsideFormerRecencyCap() async throws {
        let paths = try makePaths()
        try seedBaseSessions(at: paths.database.path)

        // Former candidateCap(limit:10) = max(200, min(200, 2000)) = 200 with
        // ORDER BY start_time DESC. Seed 220 recent weak vectors + 1 old exact
        // match so recency-capped KNN would only see weak vectors.
        var sessions: [(String, String, [Float], String)] = []
        for i in 0..<220 {
            let day = String(format: "%02d", (i % 28) + 1)
            sessions.append((
                "weak-\(i)",
                "2026-06-\(day)T12:00:00Z",
                VectorMath.l2Normalize([0.05, 0.95, 0.05]),
                "weak recent noise chunk \(i)"
            ))
        }
        sessions.append((
            "exact-old",
            "2019-01-01T00:00:00Z",
            [1, 0, 0],
            "exact semantic recall about vector memory"
        ))
        // Ensure base sessions table has rows for each id (seedBase only has s1/s2).
        try seedExtraSessions(at: paths.database.path, idsAndTimes: sessions.map { ($0.0, $0.1) })
        try seedSemanticCorpus(at: paths.database.path, model: "probe", sessions: sessions)

        let provider = try SQLiteEngramServiceReadProvider(
            databasePath: paths.database.path,
            embeddingEnvironment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
            ],
            embeddingProviderFactory: { _ in
                StaticIntegrityEmbeddingProvider { _ in [1, 0, 0] }
            }
        )

        let response = try await provider.search(
            EngramServiceSearchRequest(query: "vector memory", mode: "semantic", limit: 10)
        )

        XCTAssertEqual(response.searchModes, ["semantic"], "\(response.warning ?? "nil")")
        XCTAssertEqual(
            response.items.first?.id,
            "exact-old",
            "old exact match outside former recency cap must win; got \(response.items.map(\.id))"
        )
        XCTAssertEqual(response.items.first?.matchType, "semantic")
    }

    // MARK: - Shared breaker source coupling (M08 service side)

    func testServiceDefaultProviderFactoryUsesSharedBreaker() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "macos/EngramService/Core/EngramServiceReadProvider.swift"
            ),
            encoding: .utf8
        )
        // Service factory defaults through EngramServiceRunner which wraps
        // EmbeddingGuardrails.sharedBreaker — no private bypass on the read path.
        XCTAssertTrue(source.contains("defaultGuardedEmbeddingProvider") || source.contains("EmbeddingGuardrails"))
        let runner = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "macos/EngramService/Core/EngramServiceRunner.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(runner.contains("EmbeddingGuardrails.sharedBreaker"))
    }

    // MARK: - Helpers

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makePaths() throws -> (runtime: URL, database: URL) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-sem-integrity-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return (runtime, root.appendingPathComponent("service.sqlite"))
    }

    private func seedBaseSessions(at path: String) throws {
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
                CREATE VIRTUAL TABLE sessions_fts USING fts5(
                  session_id UNINDEXED,
                  content,
                  tokenize='trigram case_sensitive 0'
                );
                INSERT INTO sessions (
                  id, source, start_time, end_time, cwd, project, model,
                  message_count, summary, file_path, indexed_at, tier
                ) VALUES
                  ('s1', 'codex', '2026-06-01T10:00:00Z', '2026-06-01T11:00:00Z',
                   '/tmp', 'demo', 'gpt', 2, 'hello world', '/tmp/s1.jsonl',
                   '2026-06-01T11:00:00Z', 'normal'),
                  ('s2', 'codex', '2026-06-02T10:00:00Z', '2026-06-02T11:00:00Z',
                   '/tmp', 'demo', 'gpt', 2, 'memory recall', '/tmp/s2.jsonl',
                   '2026-06-02T11:00:00Z', 'normal');
                INSERT INTO sessions_fts(session_id, content) VALUES
                  ('s1', 'hello world keyword content'),
                  ('s2', 'memory recall keyword content');
                """)
        }
    }

    private func seedExtraSessions(at path: String, idsAndTimes: [(String, String)]) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            for (id, start) in idsAndTimes {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO sessions (
                      id, source, start_time, end_time, cwd, project, model,
                      message_count, summary, file_path, indexed_at, tier
                    ) VALUES (?, 'codex', ?, ?, '/tmp', 'demo', 'gpt', 1, ?, ?, ?, 'normal')
                    """,
                    arguments: [
                        id,
                        start,
                        start,
                        "session \(id)",
                        "/tmp/\(id).jsonl",
                        start,
                    ]
                )
            }
        }
    }

    private func seedSemanticCorpus(
        at path: String,
        model: String,
        sessions: [(id: String, start: String, vector: [Float], text: String)]
    ) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS semantic_chunks (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  chunk_index INTEGER NOT NULL,
                  text TEXT NOT NULL,
                  embedding BLOB,
                  model TEXT,
                  dim INTEGER,
                  created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE TABLE IF NOT EXISTS embedding_meta (
                  id INTEGER PRIMARY KEY CHECK (id = 1),
                  provider TEXT,
                  model TEXT,
                  dimension INTEGER,
                  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                DELETE FROM semantic_chunks;
                DELETE FROM embedding_meta;
                """)
            let dim = sessions.first?.vector.count ?? 3
            try db.execute(
                sql: """
                INSERT INTO embedding_meta (id, provider, model, dimension)
                VALUES (1, 'test', ?, ?)
                """,
                arguments: [model, dim]
            )
            for session in sessions {
                try db.execute(
                    sql: """
                    INSERT INTO semantic_chunks(id, session_id, chunk_index, text, embedding, model, dim)
                    VALUES (?, ?, 0, ?, ?, ?, ?)
                    """,
                    arguments: [
                        "\(session.id):c0",
                        session.id,
                        session.text,
                        VectorMath.encode(VectorMath.l2Normalize(session.vector)),
                        model,
                        session.vector.count,
                    ]
                )
            }
        }
    }
}

// MARK: - Test doubles

private actor EmbedCallCounter {
    private var value = 0
    func increment() { value += 1 }
    func count() -> Int { value }
}

private struct CountingEmbeddingProvider: EmbeddingProvider {
    let model = "probe"
    let dimension = 3
    let counter: EmbedCallCounter
    let vector: @Sendable (String) throws -> [Float]

    func embed(_ texts: [String]) async throws -> [[Float]] {
        await counter.increment()
        return try texts.map { try VectorMath.l2Normalize(vector($0)) }
    }
}

private struct StaticIntegrityEmbeddingProvider: EmbeddingProvider {
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
