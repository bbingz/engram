import XCTest
import GRDB
import Foundation
import EngramCoreRead
import EngramCoreWrite
@testable import EngramServiceCore

/// Service-level embedding guardrail tests: open breaker leaves jobs retryable
/// and telemetry surfaces breaker counters (wave-6 task 9).
final class EmbeddingGuardrailsTests: XCTestCase {
    func testOpenBreakerLeavesSessionJobsPendingAndRetryable() async throws {
        let paths = try makeGuardrailServicePaths()
        let gate = try ServiceWriterGate(
            databasePath: paths.database.path,
            runtimeDirectory: paths.runtime,
            queueTimeoutNanoseconds: 20_000_000
        )
        _ = try await gate.performWriteCommand(name: "seedOpenBreakerJobs") { writer in
            try writer.migrate()
            try writer.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (id, source, start_time, file_path, tier)
                    VALUES
                      ('sess-pending', 'codex', '2026-06-26T10:00:00Z', '/tmp/p.jsonl', 'normal'),
                      ('sess-retry', 'codex', '2026-06-26T10:01:00Z', '/tmp/r.jsonl', 'normal')
                    """)
                try db.execute(sql: """
                    INSERT INTO sessions_fts(session_id, content)
                    VALUES ('sess-pending', 'pending chunk text'),
                           ('sess-retry', 'retryable chunk text')
                    """)
                try db.execute(sql: """
                    INSERT INTO session_index_jobs
                      (id, session_id, job_kind, target_sync_version, status, retry_count)
                    VALUES
                      ('job-pending', 'sess-pending', 'embedding', 1, 'pending', 0),
                      ('job-retry', 'sess-retry', 'embedding', 1, 'failed_retryable', 2)
                    """)
            }
        }

        let clock = GuardrailTestClock()
        let breaker = EmbeddingCircuitBreaker(
            config: .init(failureThreshold: 2, cooldown: 60),
            now: { clock.now }
        )
        let failing = AlwaysFailEmbeddingProvider()
        let providerKey = EmbeddingCircuitBreaker.providerKey(for: Self.testConfig)
        let guarded = GuardedEmbeddingProvider(
            inner: failing,
            breaker: breaker,
            providerKey: providerKey
        )

        // Trip the breaker (N=2).
        for _ in 0..<2 {
            do { _ = try await guarded.embed(["trip"]) } catch { /* expected */ }
        }
        XCTAssertEqual(breaker.state(for: providerKey), .open)

        let completed = try await EngramServiceRunner.backfillSessionEmbeddingsOnce(
            gate: gate,
            environment: [
                "ENGRAM_EMBEDDING_API_KEY": "test",
                "ENGRAM_EMBEDDING_MODEL": "probe",
                "ENGRAM_EMBEDDING_DIM": "3",
                "ENGRAM_EMBEDDING_BASE_URL": "https://api.example.com/v1",
            ],
            providerFactory: { _ in guarded },
            limit: 8,
            phaseName: "openBreakerSessionBackfill"
        )
        XCTAssertEqual(completed, 0)

        let jobs = try await gate.performWriteCommand(name: "assertJobsUnchanged") { writer in
            try writer.read { db -> [(id: String, status: String, retries: Int)] in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, status, retry_count FROM session_index_jobs
                    WHERE id IN ('job-pending', 'job-retry')
                    ORDER BY id
                    """
                )
                return rows.map { row in
                    (
                        id: row["id"] as String? ?? "",
                        status: row["status"] as String? ?? "",
                        retries: row["retry_count"] as Int? ?? -1
                    )
                }
            }
        }.value
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs[0].id, "job-pending")
        XCTAssertEqual(jobs[0].status, "pending")
        XCTAssertEqual(jobs[0].retries, 0)
        XCTAssertEqual(jobs[1].id, "job-retry")
        XCTAssertEqual(jobs[1].status, "failed_retryable")
        XCTAssertEqual(jobs[1].retries, 2)

        let chunks = try await gate.performWriteCommand(name: "assertNoChunks") { writer in
            try writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_chunks") ?? 0
            }
        }.value
        XCTAssertEqual(chunks, 0)
        // Provider must not have been called during the open-breaker backfill.
        let calls = await failing.callCount()
        XCTAssertEqual(calls, 2, "only the two trip embeds should hit the provider")
    }

    func testTelemetrySnapshotIncludesBreakerCounters() async throws {
        let clock = GuardrailTestClock()
        let breaker = EmbeddingCircuitBreaker(
            config: .init(failureThreshold: 2, cooldown: 60),
            now: { clock.now }
        )
        let collector = ServiceTelemetryCollector(embeddingBreaker: breaker)
        let key = "https://api.example.com/v1|probe"
        for _ in 0..<2 {
            try breaker.allowRequest(providerKey: key)
            breaker.recordTransportFailure(providerKey: key)
        }
        XCTAssertEqual(breaker.state(for: key), .open)
        // Rejection while open.
        XCTAssertThrowsError(try breaker.allowRequest(providerKey: key))

        let snapshot = await collector.snapshot()
        let entry = try XCTUnwrap(snapshot.embeddingBreakers.first(where: { $0.providerKey == key }))
        XCTAssertEqual(entry.state, "open")
        XCTAssertEqual(entry.opens, 1)
        XCTAssertEqual(entry.transportFailures, 2)
        XCTAssertEqual(entry.rejections, 1)
        XCTAssertEqual(entry.consecutiveFailures, 2)
    }

    private static let testConfig = EmbeddingConfig(
        baseURL: "https://api.example.com/v1",
        apiKey: "test",
        model: "probe",
        dimension: 3
    )

    private func makeGuardrailServicePaths() throws -> (runtime: URL, socket: URL, database: URL) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-guardrail-\(UUID().uuidString.prefix(8))", isDirectory: true)
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
}

// MARK: - Helpers

private final class GuardrailTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 2_000_000)
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }
}

private actor AlwaysFailEmbeddingProvider: EmbeddingProvider {
    let model = "probe"
    let dimension = 3
    private var calls = 0

    func callCount() -> Int { calls }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        calls += 1
        throw EmbeddingError.http(503)
    }
}
