import GRDB
import Foundation
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class IndexerParityTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("indexer-parity-\(UUID().uuidString).sqlite")
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

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixtureRoot: URL {
        repoRoot
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/indexer-parity")
    }

    func testSwiftIndexerMatchesNodeDBChecksumFixtureForCodex() async throws {
        let expected = try expectedFixture()
        let codexRoot = fixtureRoot.appendingPathComponent("fixture-root/codex")
        let collector = SwiftIndexer(
            sink: NoopIndexingWriteSink(),
            adapters: [CodexAdapter(sessionsRoot: codexRoot.path)],
            authoritativeNode: "fixture-node"
        )
        let snapshots = try await collector.collectSnapshots()

        try writer.write { db in
            let sink = SessionBatchUpsert(db: db)
            _ = try sink.upsertBatch(snapshots, reason: .initialScan)
            _ = try StartupBackfills.backfillSuggestedParents(db)

            XCTAssertEqual(snapshots.count, expected.indexedCount)
            try assertTable("sessions", orderBy: "id", expected: expected.tables.sessions, db: db)
            try assertTable("session_costs", orderBy: "session_id, model", expected: expected.tables.session_costs, db: db)
            try assertTable("session_tools", orderBy: "session_id, tool_name", expected: expected.tables.session_tools, db: db)
            try assertTable("session_files", orderBy: "session_id, file_path, action", expected: expected.tables.session_files, db: db)
            try assertTable("session_index_jobs", orderBy: "id", expected: expected.tables.session_index_jobs, db: db)
            XCTAssertEqual(
                try selectedMetadata(db),
                expected.tables.metadata.rows,
                "metadata"
            )
            let parentRows = try normalizedRows(
                Row.fetchAll(
                    db,
                    sql: "SELECT id, parent_session_id, suggested_parent_id, link_source FROM sessions ORDER BY id"
                )
            )
            XCTAssertEqual(stableString(parentRows), stableString(expected.parentLinkColumns.rows))
        }
    }

    func testComputeTierMatchesNodeReferenceCases() {
        XCTAssertEqual(SessionTier.compute(TierInput(agentRole: "subagent")), .skip)
        XCTAssertEqual(SessionTier.compute(TierInput(filePath: "/home/user/.claude/projects/abc/subagents/xyz.jsonl")), .skip)
        XCTAssertEqual(SessionTier.compute(TierInput(messageCount: 1)), .skip)
        XCTAssertEqual(SessionTier.compute(TierInput(messageCount: 5, isPreamble: true)), .skip)
        XCTAssertEqual(SessionTier.compute(TierInput(messageCount: 2, filePath: "/Users/x/.engram/probes/claude/session.jsonl")), .skip)
        XCTAssertEqual(SessionTier.compute(TierInput(messageCount: 20)), .premium)
        XCTAssertEqual(SessionTier.compute(TierInput(messageCount: 10, project: "my-project")), .premium)
        XCTAssertEqual(
            SessionTier.compute(
                TierInput(
                    startTime: "2024-01-01T10:00:00Z",
                    endTime: "2024-01-01T10:40:00Z"
                )
            ),
            .premium
        )
        XCTAssertEqual(SessionTier.compute(TierInput(messageCount: 3, assistantCount: 0, toolCount: 0)), .lite)
        XCTAssertEqual(SessionTier.compute(TierInput(summary: "Check /usage limits")), .lite)
        XCTAssertEqual(SessionTier.compute(TierInput(messageCount: 3, summary: "Refactored auth module")), .normal)
    }

    func testSessionSnapshotWriterPersistsSnapshotCostsAndJobsThenNoops() throws {
        try writer.write { db in
            let snapshot = makeSnapshot(id: "sess-1", tier: .normal)
            let writer = SessionSnapshotWriter(db: db)
            let first = try writer.writeAuthoritativeSnapshot(snapshot)
            let second = try writer.writeAuthoritativeSnapshot(snapshot)

            XCTAssertEqual(first.action, .merge)
            XCTAssertEqual(second.action, .noop)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT summary FROM sessions WHERE id = 'sess-1'"), "hello")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_costs WHERE session_id = 'sess-1'"), 1)
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT job_kind FROM session_index_jobs WHERE session_id = 'sess-1' ORDER BY job_kind"),
                ["embedding", "fts"]
            )
        }
    }

    func testTierGatedIndexJobs() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "skip", tier: .skip))
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "lite", tier: .lite))
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "normal", tier: .normal))

            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_index_jobs WHERE session_id = 'skip'"), 0)
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT job_kind FROM session_index_jobs WHERE session_id = 'lite'"),
                ["fts"]
            )
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT job_kind FROM session_index_jobs WHERE session_id = 'normal' ORDER BY job_kind"),
                ["embedding", "fts"]
            )
        }
    }

    func testFilePathFallbackDoesNotOverwriteExistingLocalPathOrUseSyncLocator() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "local", sourceLocator: "/tmp/foo.jsonl"))
            try db.execute(sql: "UPDATE sessions SET file_path = '/real/local/path.jsonl' WHERE id = 'local'")
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "local", syncVersion: 2, snapshotHash: "h2", sourceLocator: "/tmp/foo.jsonl"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT file_path FROM sessions WHERE id = 'local'"),
                "/real/local/path.jsonl"
            )

            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "remote", sourceLocator: "sync://peer/abc"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT file_path FROM sessions WHERE id = 'remote'"), "")
        }
    }

    func testSessionBatchUpsertReportsPerSessionResults() throws {
        try writer.write { db in
            let sink = SessionBatchUpsert(db: db)
            let result = try sink.upsertBatch(
                [
                    makeSnapshot(id: "batch-1", tier: .normal),
                    makeSnapshot(id: "batch-2", tier: .skip)
                ],
                reason: .initialScan
            )

            XCTAssertEqual(result.results.map(\.sessionId), ["batch-1", "batch-2"])
            XCTAssertEqual(result.results.map(\.action), [.merge, .merge])
            XCTAssertEqual(result.results[0].enqueuedJobs.map(\.rawValue).sorted(), ["embedding", "fts"])
            XCTAssertEqual(result.results[1].enqueuedJobs, [])
        }
    }

    func testIndexAllFlushesSnapshotsInBoundedBatches() async throws {
        let sink = RecordingBatchSink()
        let indexer = SwiftIndexer(
            sink: sink,
            adapters: [SyntheticSessionAdapter(count: 205)]
        )

        let indexed = try await indexer.indexAll()

        XCTAssertEqual(indexed, 205)
        XCTAssertEqual(sink.batchSizes, [100, 100, 5])
    }

    func testStreamSnapshotsExposesBoundedConsumerPath() async throws {
        let indexer = SwiftIndexer(
            sink: NoopIndexingWriteSink(),
            adapters: [SyntheticSessionAdapter(count: 3)]
        )
        var ids: [String] = []

        for try await snapshot in indexer.streamSnapshots() {
            ids.append(snapshot.id)
            if ids.count == 2 {
                break
            }
        }

        XCTAssertEqual(ids, ["synthetic-0", "synthetic-1"])
    }

    private func makeSnapshot(
        id: String,
        syncVersion: Int = 1,
        snapshotHash: String = "h1",
        sourceLocator: String = "/tmp/rollout.jsonl",
        tier: SessionTier = .normal
    ) -> AuthoritativeSessionSnapshot {
        AuthoritativeSessionSnapshot(
            id: id,
            source: .codex,
            authoritativeNode: "node-a",
            syncVersion: syncVersion,
            snapshotHash: snapshotHash,
            indexedAt: "2026-03-18T12:00:00Z",
            sourceLocator: sourceLocator,
            sizeBytes: 128,
            startTime: "2026-03-18T11:00:00Z",
            endTime: nil,
            cwd: "/repo",
            project: nil,
            model: "openai",
            messageCount: 2,
            userMessageCount: 1,
            assistantMessageCount: 1,
            toolMessageCount: 0,
            systemMessageCount: 0,
            summary: "hello",
            summaryMessageCount: nil,
            origin: nil,
            tier: tier,
            agentRole: nil
        )
    }

    private func expectedFixture() throws -> ExpectedIndexerFixture {
        let url = fixtureRoot.appendingPathComponent("expected-db-checksums.json")
        return try JSONDecoder().decode(ExpectedIndexerFixture.self, from: Data(contentsOf: url))
    }

    private func assertTable(
        _ table: String,
        orderBy: String,
        expected: ExpectedTable,
        db: Database
    ) throws {
        let actualRows = try normalizedRows(Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY \(orderBy)"))
        XCTAssertEqual(actualRows.count, expected.count, table)
        XCTAssertEqual(stableString(actualRows), stableString(expected.rows), table)
    }

    private func selectedMetadata(_ db: Database) throws -> [String: String] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT key, value FROM metadata WHERE key IN ('schema_version', 'fts_version') ORDER BY key"
        )
        var output: [String: String] = [:]
        for row in rows {
            output[row["key"]] = row["value"]
        }
        return output
    }

    private func normalizedRows(_ rows: [Row]) -> [[String: AnyValue]] {
        rows.map { row in
            var output: [String: AnyValue] = [:]
            for column in row.columnNames {
                output[column] = normalizedValue(row[column], column: column)
            }
            return output
        }
    }

    private func normalizedValue(_ value: DatabaseValue, column: String) -> AnyValue {
        if [
            "indexed_at",
            "created_at",
            "computed_at",
            "updated_at",
            "last_indexed",
            "link_checked_at"
        ].contains(column) {
            return .string("<volatile>")
        }

        switch value.storage {
        case .null:
            return .null
        case .int64(let value):
            return .int(value)
        case .double(let value):
            return .double(value)
        case .string(let value):
            return .string(value.replacingOccurrences(of: repoRoot.deletingLastPathComponent().path, with: "<repo>"))
        case .blob(let data):
            return .string(data.base64EncodedString())
        }
    }

    private func stableString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(value)
        return String(data: data, encoding: .utf8)!
    }
}

private struct NoopIndexingWriteSink: IndexingWriteSink {
    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        SessionBatchUpsertResult(reason: reason, results: [])
    }
}

private final class RecordingBatchSink: IndexingWriteSink {
    var batchSizes: [Int] = []

    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        batchSizes.append(snapshots.count)
        return SessionBatchUpsertResult(
            reason: reason,
            results: snapshots.map {
                SessionBatchItemResult(sessionId: $0.id, action: .merge, enqueuedJobs: [])
            }
        )
    }
}

private final class SyntheticSessionAdapter: SessionAdapter {
    let source: SourceName = .codex
    private let count: Int

    init(count: Int) {
        self.count = count
    }

    func detect() async -> Bool {
        true
    }

    func listSessionLocators() async throws -> [String] {
        (0..<count).map { "synthetic://\($0)" }
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        let id = locator.replacingOccurrences(of: "synthetic://", with: "synthetic-")
        return .success(
            NormalizedSessionInfo(
                id: id,
                source: .codex,
                startTime: "2026-04-24T00:00:00Z",
                cwd: "/repo",
                model: "synthetic",
                messageCount: 2,
                userMessageCount: 1,
                assistantMessageCount: 1,
                toolMessageCount: 0,
                systemMessageCount: 0,
                summary: "hello",
                filePath: locator,
                sizeBytes: 128
            )
        )
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(NormalizedMessage(role: .user, content: "hello"))
            continuation.yield(NormalizedMessage(role: .assistant, content: "done"))
            continuation.finish()
        }
    }

    func isAccessible(locator: String) async -> Bool {
        true
    }
}

private struct ExpectedIndexerFixture: Decodable {
    var indexedCount: Int
    var tables: ExpectedTables
    var parentLinkColumns: ParentLinkColumns
}

private struct ExpectedTables: Decodable {
    var sessions: ExpectedTable
    var session_costs: ExpectedTable
    var session_tools: ExpectedTable
    var session_files: ExpectedTable
    var session_index_jobs: ExpectedTable
    var metadata: ExpectedMetadataTable
}

private struct ExpectedTable: Decodable {
    var count: Int
    var rows: [[String: AnyValue]]
}

private struct ExpectedMetadataTable: Decodable {
    var count: Int
    var rows: [String: String]
}

private struct ParentLinkColumns: Decodable {
    var rows: [[String: AnyValue]]
}

private enum AnyValue: Codable, Equatable {
    case null
    case string(String)
    case int(Int64)
    case double(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        }
    }
}
