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
            let snapshot = makeSnapshot(
                id: "sess-1",
                tier: .normal,
                tokenUsage: TokenUsage(
                    inputTokens: 120,
                    outputTokens: 30,
                    cacheReadTokens: 40,
                    cacheCreationTokens: 10
                )
            )
            let writer = SessionSnapshotWriter(db: db)
            let first = try writer.writeAuthoritativeSnapshot(snapshot)
            let second = try writer.writeAuthoritativeSnapshot(snapshot)

            XCTAssertEqual(first.action, .merge)
            XCTAssertEqual(second.action, .noop)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT summary FROM sessions WHERE id = 'sess-1'"), "hello")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_costs WHERE session_id = 'sess-1'"), 1)
            let costRow = try Row.fetchOne(
                db,
                sql: """
                SELECT input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd
                FROM session_costs
                WHERE session_id = 'sess-1'
                """
            )
            XCTAssertEqual(costRow?["input_tokens"] as Int?, 120)
            XCTAssertEqual(costRow?["output_tokens"] as Int?, 30)
            XCTAssertEqual(costRow?["cache_read_tokens"] as Int?, 40)
            XCTAssertEqual(costRow?["cache_creation_tokens"] as Int?, 10)
            XCTAssertNil(costRow?["cost_usd"] as Double?)
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT job_kind FROM session_index_jobs WHERE session_id = 'sess-1' ORDER BY job_kind"),
                ["embedding", "fts"]
            )
        }
    }

    func testSessionSnapshotWriterComputesKnownModelCost() throws {
        try writer.write { db in
            let snapshot = makeSnapshot(
                id: "costed-claude",
                model: "claude-sonnet-4-6",
                tokenUsage: TokenUsage(
                    inputTokens: 1_000_000,
                    outputTokens: 100_000,
                    cacheReadTokens: 500_000,
                    cacheCreationTokens: 10_000
                )
            )
            _ = try SessionSnapshotWriter(db: db).writeAuthoritativeSnapshot(snapshot)

            let cost = try XCTUnwrap(Double.fetchOne(
                db,
                sql: "SELECT cost_usd FROM session_costs WHERE session_id = ?",
                arguments: [snapshot.id]
            ))

            XCTAssertEqual(cost, 4.6875, accuracy: 0.000_001)
        }
    }

    func testSessionSnapshotWriterLinkSourceTruthTable() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "parent"))
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "manual-parent"))

            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(id: "fresh-path", parentSessionId: "parent")
            )
            var row = try Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, link_source FROM sessions WHERE id = 'fresh-path'"
            )
            XCTAssertEqual(row?["parent_session_id"] as String?, "parent")
            XCTAssertEqual(row?["link_source"] as String?, "path")

            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(id: "fresh-path", syncVersion: 2, snapshotHash: "h2")
            )
            row = try Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, link_source FROM sessions WHERE id = 'fresh-path'"
            )
            XCTAssertEqual(row?["parent_session_id"] as String?, "parent")
            XCTAssertEqual(row?["link_source"] as String?, "path")

            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(id: "fresh-path", syncVersion: 3, snapshotHash: "h3", parentSessionId: "manual-parent")
            )
            row = try Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, link_source FROM sessions WHERE id = 'fresh-path'"
            )
            XCTAssertEqual(row?["parent_session_id"] as String?, "manual-parent")
            XCTAssertEqual(row?["link_source"] as String?, "path")

            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "fresh-null"))
            row = try Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, link_source FROM sessions WHERE id = 'fresh-null'"
            )
            XCTAssertNil(row?["parent_session_id"] as String?)
            XCTAssertNil(row?["link_source"] as String?)

            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(id: "fresh-null", syncVersion: 2, snapshotHash: "h2", parentSessionId: "parent")
            )
            row = try Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, link_source FROM sessions WHERE id = 'fresh-null'"
            )
            XCTAssertEqual(row?["parent_session_id"] as String?, "parent")
            XCTAssertEqual(row?["link_source"] as String?, "path")

            try db.execute(
                sql: """
                UPDATE sessions
                SET parent_session_id = 'manual-parent',
                    link_source = 'manual'
                WHERE id = 'fresh-path'
                """
            )
            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(id: "fresh-path", syncVersion: 4, snapshotHash: "h4", parentSessionId: "parent")
            )
            row = try Row.fetchOne(
                db,
                sql: "SELECT parent_session_id, link_source FROM sessions WHERE id = 'fresh-path'"
            )
            XCTAssertEqual(row?["parent_session_id"] as String?, "manual-parent")
            XCTAssertEqual(row?["link_source"] as String?, "manual")
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

    func testSameHashSnapshotCanRefreshSizeBytesOnly() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "size-only", sizeBytes: 128))

            let result = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(
                    id: "size-only",
                    snapshotHash: "h1",
                    sizeBytes: 1_198
                )
            )

            XCTAssertEqual(result.action, .merge)
            XCTAssertEqual(result.changeSet.flags, [.syncPayloadChanged])
            XCTAssertEqual(
                try Int64.fetchOne(db, sql: "SELECT size_bytes FROM sessions WHERE id = 'size-only'"),
                1_198
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_index_jobs WHERE session_id = 'size-only'"),
                2
            )
        }
    }

    func testSameSyncVersionSnapshotCanRecoverTierFromSkip() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "tier-recovery", tier: .skip))

            let result = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(id: "tier-recovery", snapshotHash: "h2", tier: .premium)
            )

            XCTAssertEqual(result.action, .merge)
            XCTAssertEqual(
                result.changeSet.flags,
                [.syncPayloadChanged, .localStateChanged, .searchTextChanged, .embeddingTextChanged]
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'tier-recovery'"),
                "premium"
            )
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT job_kind FROM session_index_jobs WHERE session_id = 'tier-recovery' ORDER BY job_kind"),
                ["embedding", "fts"]
            )
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

    func testSessionSnapshotWriterPreservesSessionToolsOnEmptyNoopSnapshots() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(id: "tool-refresh", toolCallCounts: ["read_file": 1])
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT call_count FROM session_tools WHERE session_id = 'tool-refresh' AND tool_name = 'read_file'"),
                1
            )

            let noop = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "tool-refresh"))

            XCTAssertEqual(noop.action, .noop)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT call_count FROM session_tools WHERE session_id = 'tool-refresh' AND tool_name = 'read_file'"),
                1
            )
        }
    }

    func testSessionSnapshotWriterCanRefreshNonEmptyNoopSessionTools() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(id: "tool-refresh-non-empty", toolCallCounts: ["read_file": 1])
            )

            let noop = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(id: "tool-refresh-non-empty", toolCallCounts: ["write_file": 2])
            )

            XCTAssertEqual(noop.action, .noop)
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT tool_name || ':' || call_count FROM session_tools WHERE session_id = 'tool-refresh-non-empty' ORDER BY tool_name"),
                ["write_file:2"]
            )
        }
    }

    func testSessionSnapshotWriterKeepsNilModelAsNullInZeroCostRows() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "nil-model", model: nil))

            XCTAssertNil(try String.fetchOne(db, sql: "SELECT model FROM session_costs WHERE session_id = 'nil-model'"))
        }
    }

    func testSessionSnapshotWriterRefreshesNoopCostModelWithoutClearingExistingModel() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "noop-model", model: nil))

            let modelUpdate = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "noop-model", model: "claude-opus"))

            XCTAssertEqual(modelUpdate.action, .noop)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT model FROM session_costs WHERE session_id = 'noop-model'"),
                "claude-opus"
            )

            let nilUpdate = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "noop-model", model: nil))

            XCTAssertEqual(nilUpdate.action, .noop)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT model FROM session_costs WHERE session_id = 'noop-model'"),
                "claude-opus"
            )
        }
    }

    func testSessionSnapshotWriterBackfillsNoopTokenUsageCosts() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "noop-usage-backfill"))

            let initialCostRow = try Row.fetchOne(
                db,
                sql: """
                SELECT input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens
                FROM session_costs
                WHERE session_id = 'noop-usage-backfill'
                """
            )
            XCTAssertEqual(initialCostRow?["input_tokens"] as Int?, 0)
            XCTAssertEqual(initialCostRow?["output_tokens"] as Int?, 0)
            XCTAssertEqual(initialCostRow?["cache_read_tokens"] as Int?, 0)
            XCTAssertEqual(initialCostRow?["cache_creation_tokens"] as Int?, 0)

            let update = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(
                    id: "noop-usage-backfill",
                    tokenUsage: TokenUsage(
                        inputTokens: 123,
                        outputTokens: 45,
                        cacheReadTokens: 6,
                        cacheCreationTokens: 7
                    )
                )
            )

            XCTAssertEqual(update.action, .noop)
            let backfilledCostRow = try Row.fetchOne(
                db,
                sql: """
                SELECT input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens
                FROM session_costs
                WHERE session_id = 'noop-usage-backfill'
                """
            )
            XCTAssertEqual(backfilledCostRow?["input_tokens"] as Int?, 123)
            XCTAssertEqual(backfilledCostRow?["output_tokens"] as Int?, 45)
            XCTAssertEqual(backfilledCostRow?["cache_read_tokens"] as Int?, 6)
            XCTAssertEqual(backfilledCostRow?["cache_creation_tokens"] as Int?, 7)
        }
    }

    func testUsageParserBackfillPolicyNeedsBackfillUntilCurrentVersionRecorded() throws {
        try writer.write { db in
            XCTAssertTrue(try UsageParserBackfillPolicy.needsBackfill(db))

            try db.execute(
                sql: "INSERT INTO metadata(key, value) VALUES (?, ?)",
                arguments: [UsageParserBackfillPolicy.metadataKey, "1"]
            )
            XCTAssertTrue(try UsageParserBackfillPolicy.needsBackfill(db))

            try UsageParserBackfillPolicy.markComplete(db)

            XCTAssertFalse(try UsageParserBackfillPolicy.needsBackfill(db))
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT value FROM metadata WHERE key = ?",
                    arguments: [UsageParserBackfillPolicy.metadataKey]
                ),
                UsageParserBackfillPolicy.currentVersion
            )
        }
    }

    func testUsageParserBackfillPolicyVersionCoversOpenCodeReasoningUsage() {
        XCTAssertEqual(UsageParserBackfillPolicy.currentVersion, "4")
    }

    func testSessionSnapshotWriterDoesNotRewriteUnchangedNoopCostRows() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "noop-cost", model: "claude-opus"))

            let before = try Int.fetchOne(db, sql: "SELECT total_changes()") ?? 0
            let noop = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "noop-cost", model: "claude-opus"))
            let after = try Int.fetchOne(db, sql: "SELECT total_changes()") ?? 0

            XCTAssertEqual(noop.action, .noop)
            XCTAssertEqual(after, before)
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

    func testStartupIndexAllSkipsUnchangedFileLocatorsOnSecondRun() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-index-skip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("session.jsonl")
        try "synthetic\n".write(to: locator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: locator.path
        )
        let adapter = CountingSyntheticFileSessionAdapter(locator: locator.path)

        let first = try await writer.indexAllSessions(adapters: [adapter])
        let firstStreamCount = adapter.streamCount
        let second = try await writer.indexAllSessions(adapters: [adapter])

        XCTAssertEqual(first.indexed, 1)
        XCTAssertEqual(firstStreamCount, 1)
        XCTAssertEqual(second.indexed, 0)
        XCTAssertEqual(adapter.streamCount, 1, "unchanged startup index must not reparse message streams")
    }

    func testStartupIndexAllDefersKnownHotFileLocators() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-index-hot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("session.jsonl")
        try "synthetic\n".write(to: locator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: locator.path
        )
        let adapter = CountingSyntheticFileSessionAdapter(locator: locator.path)

        let first = try await writer.indexAllSessions(adapters: [adapter])
        try "hello\nstill writing\n".write(to: locator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: locator.path)
        let firstStreamCount = adapter.streamCount
        let second = try await writer.indexAllSessions(adapters: [adapter])

        XCTAssertEqual(first.indexed, 1)
        XCTAssertEqual(second.indexed, 0)
        XCTAssertEqual(adapter.streamCount, firstStreamCount, "startup index should defer known files still being written")
    }

    func testStartupIndexAllSkipsKnownModifiedFileLocators() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-index-known-modified-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("session.jsonl")
        try "hello\n".write(to: locator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: locator.path
        )
        let adapter = CountingSyntheticFileSessionAdapter(locator: locator.path)

        let first = try await writer.indexAllSessions(adapters: [adapter])
        try "hello\nlater change\n".write(to: locator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: locator.path
        )
        let firstStreamCount = adapter.streamCount
        let second = try await writer.indexAllSessions(adapters: [adapter])

        XCTAssertEqual(first.indexed, 1)
        XCTAssertEqual(second.indexed, 0)
        XCTAssertEqual(adapter.streamCount, firstStreamCount, "startup all-scan must not reparse known modified locators")
    }

    /// Wave 7A C01: startup deferral must not stamp success for a grown identity,
    /// and a subsequent recent scan must reparse the changed file.
    func testStartupDeferralDoesNotStampSuccess_recentScanRecovers_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-deferral-recover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("session.jsonl")
        try "hello\n".write(to: locator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: locator.path
        )
        let adapter = CountingSyntheticFileSessionAdapter(
            locator: locator.path,
            userContent: "hello",
            assistantContent: "first"
        )

        let first = try await writer.indexAllSessions(adapters: [adapter])
        XCTAssertEqual(first.indexed, 1)
        let afterFirst = adapter.streamCount

        try "hello\nlater change\n".write(to: locator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: locator.path
        )

        // Startup all-scan still defers (no reparse) but must leave identity dirty.
        let deferred = try await writer.indexAllSessions(adapters: [adapter])
        XCTAssertEqual(deferred.indexed, 0)
        XCTAssertEqual(adapter.streamCount, afterFirst)

        let grownStat = FileIndexStat.directFileStat(locator: locator.path)
        let parseState = try writer.knownFileIndexStates(source: .codex, locators: [locator.path])[locator.path]
        if let parseState, let grownStat {
            XCTAssertFalse(
                parseState.sameFileIdentity(as: grownStat),
                "deferral must not advance file_index_state to the unparsed grown identity"
            )
        }

        // Recent scan (skipKnownFileLocators: false) recovers content.
        let recovered = try await writer.indexRecentSessions(adapters: [adapter])
        XCTAssertGreaterThan(adapter.streamCount, afterFirst, "recent scan must reparse the grown file")
        XCTAssertGreaterThanOrEqual(recovered.indexed, 0)
    }

    /// Wave 7A M03: active-file grace defers without stamping success.
    func testActiveFileGraceDoesNotStampSuccess_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("active-file-grace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("session.jsonl")
        try "hello\n".write(to: locator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: locator.path
        )
        let adapter = CountingSyntheticFileSessionAdapter(locator: locator.path)

        _ = try await writer.indexAllSessions(adapters: [adapter])

        // New locator never seen in file_index_state: simulate by deleting state,
        // keeping the sessions row so knownIndexedState still resolves.
        try writer.write { db in
            try db.execute(sql: "DELETE FROM file_index_state WHERE locator = ?", arguments: [locator.path])
        }
        try "hello\nstill writing\n".write(to: locator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: locator.path)

        let streamBefore = adapter.streamCount
        let recent = try await writer.indexRecentSessions(adapters: [adapter])
        XCTAssertEqual(recent.indexed, 0)
        XCTAssertEqual(adapter.streamCount, streamBefore, "hot file grace defers parse")

        let parseState = try writer.knownFileIndexStates(source: .codex, locators: [locator.path])[locator.path]
        XCTAssertNil(parseState, "active-file grace must not insert a success row for an unparsed identity")
    }

    /// Wave 7A H10: same message counts + same summary but different body text
    /// must produce different snapshotHash values (content fingerprint).
    func testSameCountBodyRewriteEnqueuesFtsJob_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("body-rewrite-fts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locatorA = root.appendingPathComponent("a.jsonl")
        let locatorB = root.appendingPathComponent("b.jsonl")
        try "a\n".write(to: locatorA, atomically: true, encoding: .utf8)
        try "b\n".write(to: locatorB, atomically: true, encoding: .utf8)

        // Two locators, identical metadata counts/summary in parseSessionInfo,
        // different user body text → content fingerprint must diverge.
        let adapterA = CountingSyntheticFileSessionAdapter(
            locator: locatorA.path,
            sessionId: "body-a",
            userContent: "alpha body",
            assistantContent: "done"
        )
        let adapterB = CountingSyntheticFileSessionAdapter(
            locator: locatorB.path,
            sessionId: "body-b",
            userContent: "beta body rewritten",
            assistantContent: "done"
        )
        _ = try await writer.indexRecentSessions(adapters: [adapterA])
        _ = try await writer.indexRecentSessions(adapters: [adapterB])

        let hashA = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT snapshot_hash FROM sessions WHERE id = 'body-a'")
        }
        let hashB = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT snapshot_hash FROM sessions WHERE id = 'body-b'")
        }
        XCTAssertNotNil(hashA)
        XCTAssertNotNil(hashB)
        XCTAssertNotEqual(hashA, hashB, "body text must participate in snapshotHash")

        let pendingFts = try writer.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM session_index_jobs
                WHERE session_id IN ('body-a', 'body-b') AND job_kind = 'fts' AND status = 'pending'
                """
            ) ?? 0
        }
        XCTAssertGreaterThan(pendingFts, 0, "new sessions must enqueue FTS")
    }

    func testFileIndexDecisionSkipsTerminalFailureUntilFileChanges() {
        let now = Date(timeIntervalSince1970: 2_000)
        let stat = FileIndexStat(
            sizeBytes: 128,
            modifiedAtNanos: 1_000_000_000,
            inode: 42,
            device: 7
        )
        let state = FileIndexState.failure(
            source: .codex,
            locator: "/tmp/bad.jsonl",
            stat: stat,
            failure: .lineTooLarge,
            previous: nil,
            now: now
        )

        XCTAssertEqual(FileIndexDecision.decide(stat: stat, state: state, now: now), .skip)
        XCTAssertEqual(
            FileIndexDecision.decide(
                stat: FileIndexStat(sizeBytes: 256, modifiedAtNanos: stat.modifiedAtNanos, inode: stat.inode, device: stat.device),
                state: state,
                now: now
            ),
            .full
        )
    }

    func testFileIndexDecisionBacksOffMalformedFailureBeforeRetryAfter() {
        let now = Date(timeIntervalSince1970: 2_000)
        let stat = FileIndexStat(
            sizeBytes: 128,
            modifiedAtNanos: 1_000_000_000,
            inode: 42,
            device: 7
        )
        let state = FileIndexState.failure(
            source: .codex,
            locator: "/tmp/partial.jsonl",
            stat: stat,
            failure: .malformedJSON,
            previous: nil,
            now: now
        )

        XCTAssertEqual(FileIndexDecision.decide(stat: stat, state: state, now: now), .skip)
        XCTAssertEqual(
            FileIndexDecision.decide(stat: stat, state: state, now: now.addingTimeInterval(10 * 60)),
            .full
        )
    }

    func testFileIndexDecisionSchemaVersionMismatchForcesFull() {
        let now = Date(timeIntervalSince1970: 2_000)
        let stat = FileIndexStat(
            sizeBytes: 128,
            modifiedAtNanos: 1_000_000_000,
            inode: 42,
            device: 7
        )
        var state = FileIndexState.success(source: .codex, locator: "/tmp/ok.jsonl", stat: stat, now: now)
        state.schemaVersion = FileIndexState.currentSchemaVersion - 1

        XCTAssertEqual(FileIndexDecision.decide(stat: stat, state: state, now: now), .full)
    }

    func testStartupIndexCachesTerminalParseFailureAndSkipsNextRun() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-index-terminal-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("bad.jsonl")
        try "bad\n".write(to: locator, atomically: true, encoding: .utf8)
        let adapter = FailingFileSessionAdapter(locator: locator.path, failure: .lineTooLarge)

        let first = try await writer.indexAllSessions(adapters: [adapter])
        let second = try await writer.indexAllSessions(adapters: [adapter])

        XCTAssertEqual(first.indexed, 0)
        XCTAssertEqual(second.indexed, 0)
        XCTAssertEqual(adapter.parseCount, 1, "terminal parse failures must be cached until the file changes")
    }

    func testStartupIndexSkipsRetryFailureBeforeRetryAfter() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-index-retry-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("partial.jsonl")
        try "partial\n".write(to: locator, atomically: true, encoding: .utf8)
        let stat = try XCTUnwrap(FileIndexStat.directFileStat(locator: locator.path))
        let state = FileIndexState.failure(
            source: .codex,
            locator: locator.path,
            stat: stat,
            failure: .malformedJSON,
            previous: nil,
            now: Date()
        )
        try writer.upsertFileIndexState(state)
        let adapter = FailingFileSessionAdapter(locator: locator.path, failure: .malformedJSON)

        let result = try await writer.indexAllSessions(adapters: [adapter])

        XCTAssertEqual(result.indexed, 0)
        XCTAssertEqual(adapter.parseCount, 0, "retryable parse failures should honor retry_after before reparsing")
    }

    func testStartupIndexBackfillsFileIndexStateWhenSkippingKnownSessionLocatorWithInstructionSignals() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-index-manifest-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("session.jsonl")
        try "hello\n".write(to: locator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: locator.path
        )
        let size = try XCTUnwrap(FileIndexStat.directFileStat(locator: locator.path)).sizeBytes
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(
                    id: "legacy-known",
                    sourceLocator: locator.path,
                    sizeBytes: size,
                    instructionCount: 1,
                    humanTurnCount: 1,
                    instructionSummary: "hello"
                )
            )
        }
        let adapter = CountingSyntheticFileSessionAdapter(locator: locator.path)

        let result = try await writer.indexAllSessions(adapters: [adapter])
        let states = try writer.knownFileIndexStates(source: .codex, locators: [locator.path])

        XCTAssertEqual(result.indexed, 0)
        XCTAssertEqual(adapter.streamCount, 0, "known locators with instruction signals should not be reparsed during startup backfill")
        // Wave 7A C01: startup deferral must not invent a success parseStatus for
        // an unparsed identity — leave state absent/dirty so later scans recover.
        XCTAssertNil(states[locator.path], "deferral must not stamp file_index_state success")
    }

    func testInstructionBackfillIndexesExistingReliableRowsMissedByAdapterListing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("instruction-backfill-explicit-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("rollout-2026-04-24T00-00-00-startup-skip.jsonl")
        try "hello\n".write(to: locator, atomically: true, encoding: .utf8)
        let size = try XCTUnwrap(FileIndexStat.directFileStat(locator: locator.path)).sizeBytes
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(
                    id: "startup-skip",
                    sourceLocator: locator.path,
                    sizeBytes: size,
                    authoritativeNode: "local"
                )
            )
            try db.execute(sql: "UPDATE session_index_jobs SET status = 'completed' WHERE session_id = 'startup-skip'")
        }
        let adapter = CountingSyntheticFileSessionAdapter(
            locator: locator.path,
            listedLocators: [],
            userContent: "Fix login bug"
        )

        let result = try await writer.indexInstructionBackfillSessions(adapters: [adapter])
        let row = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT instruction_count, human_turn_count, instruction_summary
                FROM sessions
                WHERE id = 'startup-skip'
                """
            )
        }

        XCTAssertEqual(result.indexed, 1)
        XCTAssertEqual(adapter.streamCount, 1)
        XCTAssertEqual(row?["instruction_count"] as Int?, 1)
        XCTAssertEqual(row?["human_turn_count"] as Int?, 1)
        XCTAssertEqual(row?["instruction_summary"] as String?, "Fix login bug")
    }

    func testImplementationBeatBackfillIndexesExistingReliableRowsMissedByAdapterListing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("implementation-backfill-explicit-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("rollout-2026-06-23T10-00-00-work.jsonl")
        try "hello\n".write(to: locator, atomically: true, encoding: .utf8)
        let size = try XCTUnwrap(FileIndexStat.directFileStat(locator: locator.path)).sizeBytes
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(
                    id: "work-backfill",
                    sourceLocator: locator.path,
                    sizeBytes: size,
                    authoritativeNode: "local",
                    startTime: "2026-06-23T10:00:00Z",
                    instructionCount: 1,
                    humanTurnCount: 1,
                    instructionSummary: "实现项目变更时间线第一版"
                )
            )
            try db.execute(sql: "UPDATE session_index_jobs SET status = 'completed' WHERE session_id = 'work-backfill'")
        }
        let adapter = CountingSyntheticFileSessionAdapter(
            locator: locator.path,
            listedLocators: [],
            userContent: "实现项目变更时间线第一版",
            assistantContent: """
            结果
            已完成第一版项目变更时间线。

            验证结果
            checks run: targeted tests
            """
        )

        let result = try await writer.indexImplementationBeatBackfillSessions(adapters: [adapter])
        let row = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT action_date, work_title, status, assistant_outcome
                FROM session_work_beats
                WHERE session_id = 'work-backfill' AND beat_index = 0
                """
            )
        }

        XCTAssertEqual(result.indexed, 1)
        XCTAssertEqual(adapter.streamCount, 1)
        XCTAssertEqual(row?["action_date"] as String?, "2026-06-23")
        XCTAssertEqual(row?["work_title"] as String?, "实现项目变更时间线第一版")
        XCTAssertEqual(row?["status"] as String?, "completed")
        XCTAssertTrue((row?["assistant_outcome"] as String?)?.contains("已完成第一版项目变更时间线") == true)
    }

    func testKnownIndexedFileStateStillBackfillsInstructionSignalsWhenSizeMissing() {
        XCTAssertEqual(
            KnownIndexedFileState.fromIndexedSessionRow(
                sizeBytes: nil,
                indexedAt: "2026-03-18T12:00:00Z",
                needsInstructionBackfill: true
            ),
            KnownIndexedFileState(
                sizeBytes: 0,
                indexedAt: "2026-03-18T12:00:00Z",
                needsInstructionBackfill: true
            )
        )
        XCTAssertNil(
            KnownIndexedFileState.fromIndexedSessionRow(
                sizeBytes: nil,
                indexedAt: "2026-03-18T12:00:00Z",
                needsInstructionBackfill: false
            )
        )
    }

    func testInstructionBackfillUsesFilePathWhenSourceLocatorIsEmpty() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("instruction-backfill-empty-source-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = root.appendingPathComponent("rollout-2026-04-24T00-00-00-empty-source-locator.jsonl")
        try "hello\n".write(to: locator, atomically: true, encoding: .utf8)
        let stat = try XCTUnwrap(FileIndexStat.directFileStat(locator: locator.path))
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(
                    id: "empty-source-locator",
                    sourceLocator: locator.path,
                    sizeBytes: stat.sizeBytes,
                    authoritativeNode: "local"
                )
            )
            try db.execute(sql: "UPDATE sessions SET source_locator = '', instruction_count = NULL, human_turn_count = NULL, instruction_summary = NULL WHERE id = 'empty-source-locator'")
            try db.execute(sql: "UPDATE session_index_jobs SET status = 'completed' WHERE session_id = 'empty-source-locator'")
        }
        try writer.upsertFileIndexState(
            FileIndexState.success(source: .codex, locator: locator.path, stat: stat, now: Date())
        )
        let adapter = CountingSyntheticFileSessionAdapter(
            locator: locator.path,
            listedLocators: [],
            userContent: "Fix login bug"
        )

        let result = try await writer.indexInstructionBackfillSessions(adapters: [adapter])
        let row = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT source_locator, instruction_count, human_turn_count, instruction_summary
                FROM sessions
                WHERE id = 'empty-source-locator'
                """
            )
        }

        XCTAssertEqual(result.indexed, 1)
        XCTAssertEqual(adapter.streamCount, 1)
        XCTAssertEqual(row?["source_locator"] as String?, "")
        XCTAssertEqual(row?["instruction_count"] as Int?, 1)
        XCTAssertEqual(row?["human_turn_count"] as Int?, 1)
        XCTAssertEqual(row?["instruction_summary"] as String?, "Fix login bug")
    }

    func testRecentModifiedAdapterOnlyIndexesRecentlyTouchedLocators() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-active-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldLocator = root.appendingPathComponent("old.jsonl")
        let recentLocator = root.appendingPathComponent("recent.jsonl")
        try "old\n".write(to: oldLocator, atomically: true, encoding: .utf8)
        try "recent\n".write(to: recentLocator, atomically: true, encoding: .utf8)

        let now = Date(timeIntervalSince1970: 1_800)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-1_200)],
            ofItemAtPath: oldLocator.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: recentLocator.path
        )

        let indexer = SwiftIndexer(
            sink: NoopIndexingWriteSink(),
            adapters: [
                RecentlyModifiedSessionAdapter(
                    base: SyntheticFileSessionAdapter(locators: [oldLocator.path, recentLocator.path]),
                    modifiedSince: now.addingTimeInterval(-600)
                )
            ]
        )

        let snapshots = try await indexer.collectSnapshots()

        XCTAssertEqual(snapshots.map(\.id), ["recent"])
    }

    func testRecentModifiedAdapterUsesBackingFileForVirtualLocators() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-active-virtual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDatabase = root.appendingPathComponent("old.sqlite")
        let recentDatabase = root.appendingPathComponent("recent.sqlite")
        try "old\n".write(to: oldDatabase, atomically: true, encoding: .utf8)
        try "recent\n".write(to: recentDatabase, atomically: true, encoding: .utf8)

        let now = Date(timeIntervalSince1970: 1_800)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-1_200)],
            ofItemAtPath: oldDatabase.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: recentDatabase.path
        )

        let adapter = RecentlyModifiedSessionAdapter(
            base: SyntheticFileSessionAdapter(locators: [
                "\(oldDatabase.path)::old-session",
                "\(recentDatabase.path)::recent-session",
                "\(recentDatabase.path)?composer=recent-composer"
            ]),
            modifiedSince: now.addingTimeInterval(-600)
        )

        let locators = try await adapter.listSessionLocators()

        XCTAssertEqual(
            locators,
            [
                "\(recentDatabase.path)::recent-session",
                "\(recentDatabase.path)?composer=recent-composer"
            ]
        )
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

    func testPingHealthProbeSessionsAreSkipped() async throws {
        let indexer = SwiftIndexer(
            sink: NoopIndexingWriteSink(),
            adapters: [
                SyntheticSessionAdapter(
                    count: 1,
                    userContent: "ping\n",
                    assistantContent: "pong"
                )
            ]
        )

        let snapshots = try await indexer.collectSnapshots()

        XCTAssertEqual(snapshots.count, 1)
        // A bare "ping" health probe is preamble-only noise, so it is skipped
        // (SessionTier.compute returns .skip for isPreamble) — matching this
        // test's own name and the Polycli probe-skip contract.
        XCTAssertEqual(snapshots.first?.tier, .skip)
    }

    func testToolRoleMessagesContributeToTierStats() async throws {
        let indexer = SwiftIndexer(
            sink: NoopIndexingWriteSink(),
            adapters: [ToolRoleSyntheticSessionAdapter()]
        )

        let snapshots = try await indexer.collectSnapshots()

        XCTAssertEqual(snapshots.first?.tier, .normal)
        XCTAssertEqual(snapshots.first?.summaryMessageCount, 2)
    }

    func testAssistantToolCallsWithBlankContentContributeToTierStats() async throws {
        let indexer = SwiftIndexer(
            sink: NoopIndexingWriteSink(),
            adapters: [BlankAssistantToolCallSyntheticSessionAdapter()]
        )

        let snapshots = try await indexer.collectSnapshots()

        XCTAssertEqual(snapshots.first?.tier, .normal)
        XCTAssertEqual(snapshots.first?.summaryMessageCount, 2)
        XCTAssertEqual(snapshots.first?.toolCallCounts, ["Read": 1])
    }

    func testBlankAssistantWithoutToolCallsDoesNotContributeToTierStats() async throws {
        let indexer = SwiftIndexer(
            sink: NoopIndexingWriteSink(),
            adapters: [BlankAssistantNoToolCallSyntheticSessionAdapter()]
        )

        let snapshots = try await indexer.collectSnapshots()

        XCTAssertEqual(snapshots.first?.tier, .lite)
        XCTAssertEqual(snapshots.first?.summaryMessageCount, 1)
        XCTAssertEqual(snapshots.first?.toolCallCounts, [:])
    }

    func testProviderReviewProbeSessionsAreSkipped() async throws {
        let indexer = SwiftIndexer(
            sink: NoopIndexingWriteSink(),
            adapters: [
                SyntheticSessionAdapter(
                    count: 1,
                    userContent: "No tools. Review P7.10 Stage 2 diff for blocking correctness issues. Tests passed.",
                    assistantContent: "No blocking issues."
                )
            ]
        )

        let snapshots = try await indexer.collectSnapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.tier, .skip)
    }

    func testProviderStageFactProbeSessionsAreSkipped() async throws {
        let indexer = SwiftIndexer(
            sink: NoopIndexingWriteSink(),
            adapters: [
                SyntheticSessionAdapter(
                    count: 1,
                    userContent: "No tools. Stage 3 adapter facts: planned Graylog query, stream filter, timeout.",
                    assistantContent: "No blocking issues."
                )
            ]
        )

        let snapshots = try await indexer.collectSnapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.tier, .skip)
    }

    func testPolycliHealthOkProbeSessionsAreSkipped() async throws {
        let indexer = SwiftIndexer(
            sink: NoopIndexingWriteSink(),
            adapters: [
                SyntheticSessionAdapter(
                    count: 1,
                    userContent: "Reply with POLYCLI_HEALTH_OK only.",
                    assistantContent: "POLYCLI_HEALTH_OK"
                )
            ]
        )

        let snapshots = try await indexer.collectSnapshots()

        XCTAssertEqual(snapshots.count, 1)
        // Documented Polycli health-ping probe — must be skipped at index time,
        // not just by the StartupBackfills classification pass.
        XCTAssertEqual(snapshots.first?.tier, .skip)
    }

    func testPolycliActingAsProviderProbeSessionsAreSkipped() async throws {
        let indexer = SwiftIndexer(
            sink: NoopIndexingWriteSink(),
            adapters: [
                SyntheticSessionAdapter(
                    count: 1,
                    userContent: "You are acting as qwen inside polycli. Do the task below.",
                    assistantContent: "Understood."
                )
            ]
        )

        let snapshots = try await indexer.collectSnapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.tier, .skip)
    }

    func testCodexSessionWithAgentInstructionsAndRealUserTaskIsNotSkipped() async throws {
        let indexer = SwiftIndexer(
            sink: NoopIndexingWriteSink(),
            adapters: [
                SyntheticSessionAdapter(
                    count: 1,
                    userContent: """
                    # AGENTS.md instructions for /Users/bing/-Code-/engram

                    <INSTRUCTIONS>
                    Follow the repo instructions.
                    </INSTRUCTIONS>

                    <environment_context>
                      <cwd>/Users/bing/-Code-/engram</cwd>
                    </environment_context>

                    Total Sessions
                    Avg Duration
                    """,
                    assistantContent: "Updated the sessions page."
                )
            ]
        )

        let snapshots = try await indexer.collectSnapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertNotEqual(snapshots.first?.tier, .skip)
    }

    func testCodexAdapterStripsInjectedPrefixAndPreservesRealUserTask() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-injected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let realTask = "请修复真实问题，不要丢失这个任务。"
        let injectedPrompt = """
        # AGENTS.md instructions for /Users/bing/-Code-/engram

        <INSTRUCTIONS>
        Follow the repo instructions.
        </INSTRUCTIONS>
        <environment_context>
          <cwd>/Users/bing/-Code-/engram</cwd>
        </environment_context>

        \(realTask)
        """
        let file = root.appendingPathComponent("rollout-2026-05-20T00-00-00-test.jsonl")
        try writeJSONL(
            [
                [
                    "type": "session_meta",
                    "payload": [
                        "id": "codex-injected-real-task",
                        "timestamp": "2026-05-20T00:00:00Z",
                        "cwd": "/Users/bing/-Code-/engram",
                        "model_provider": "openai"
                    ]
                ],
                [
                    "type": "response_item",
                    "timestamp": "2026-05-20T00:00:01Z",
                    "payload": [
                        "type": "message",
                        "role": "user",
                        "content": [["type": "input_text", "text": injectedPrompt]]
                    ]
                ],
                [
                    "type": "response_item",
                    "timestamp": "2026-05-20T00:00:02Z",
                    "payload": [
                        "type": "message",
                        "role": "assistant",
                        "content": [["type": "output_text", "text": "完成。"]]
                    ]
                ]
            ],
            to: file
        )

        let adapter = CodexAdapter(sessionsRoot: root.path)
        guard case let .success(info) = try await adapter.parseSessionInfo(locator: file.path) else {
            XCTFail("Codex fixture should parse")
            return
        }

        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.messageCount, 2)
        XCTAssertEqual(info.summary, realTask)

        let stream = try await adapter.streamMessages(locator: file.path, options: StreamMessagesOptions())
        var messages: [NormalizedMessage] = []
        for try await message in stream {
            messages.append(message)
        }
        XCTAssertEqual(messages.first?.content, realTask)

        let indexer = SwiftIndexer(
            sink: NoopIndexingWriteSink(),
            adapters: [adapter]
        )
        let snapshots = try await indexer.collectSnapshots()
        XCTAssertEqual(snapshots.first?.summary, realTask)
        XCTAssertNotEqual(snapshots.first?.tier, .skip)
    }

    func testSnapshotHashChangeWithSameSyncVersionEnqueuesDistinctIndexJobs() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "hash-change", snapshotHash: "h1"))
            try db.execute(sql: "UPDATE session_index_jobs SET status = 'completed' WHERE session_id = 'hash-change'")

            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(id: "hash-change", snapshotHash: "h2", sizeBytes: 256, summary: "new searchable summary")
            )

            let pendingJobIds = try String.fetchAll(
                db,
                sql: "SELECT id FROM session_index_jobs WHERE session_id = 'hash-change' AND status = 'pending' ORDER BY id"
            )
            XCTAssertEqual(
                pendingJobIds,
                ["hash-change:1:h2:embedding", "hash-change:1:h2:fts"]
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM session_index_jobs WHERE session_id = 'hash-change' AND job_kind = 'fts'"
                ),
                1,
                "new snapshot hashes must prune superseded FTS jobs for the same session"
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM session_index_jobs WHERE session_id = 'hash-change' AND job_kind = 'embedding'"
                ),
                1,
                "new snapshot hashes must prune superseded embedding jobs for the same session"
            )
        }
    }

    func testSnapshotHashChangeWithSameSummaryStillEnqueuesFtsJob() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "same-summary", snapshotHash: "h1"))
            try db.execute(sql: "UPDATE session_index_jobs SET status = 'completed' WHERE session_id = 'same-summary'")

            let result = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(
                    id: "same-summary",
                    snapshotHash: "h2",
                    sizeBytes: 256
                )
            )

            XCTAssertEqual(result.changeSet.flags, [.syncPayloadChanged, .searchTextChanged, .embeddingTextChanged])
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT job_kind FROM session_index_jobs WHERE session_id = 'same-summary' AND status = 'pending' ORDER BY job_kind"
                ),
                ["embedding", "fts"]
            )
        }
    }

    func testDowngradingSessionToSkipDeletesStaleSearchArtifacts_repro() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "downgrade", snapshotHash: "h1", tier: .normal))
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('downgrade', 'old searchable content')")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS session_embeddings(session_id TEXT PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO session_embeddings(session_id) VALUES ('downgrade')")
            try db.execute(
                sql: """
                INSERT INTO semantic_chunks(id, session_id, chunk_index, text, embedding, model, dim)
                VALUES ('downgrade:0', 'downgrade', 0, 'old searchable content', X'00', 'test-model', 1)
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS messages(
                  session_id TEXT NOT NULL,
                  msg_seq INTEGER NOT NULL,
                  content TEXT NOT NULL,
                  PRIMARY KEY(session_id, msg_seq)
                )
                """
            )
            try db.execute(
                sql: "INSERT INTO messages(session_id, msg_seq, content) VALUES ('downgrade', 0, 'old searchable content')"
            )

            // PR #141 and EMB-001 regressions: direct snapshot downgrades must
            // purge cached messages, FTS, and both embedding stores.
            _ = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(id: "downgrade", snapshotHash: "h2", tier: .skip)
            )

            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'downgrade'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_embeddings WHERE session_id = 'downgrade'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_chunks WHERE session_id = 'downgrade'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE session_id = 'downgrade'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_index_jobs WHERE session_id = 'downgrade' AND status = 'pending'"),
                0
            )
        }
    }

    func testReindexClearsRecoveredOrphanStatus() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "recovered", snapshotHash: "h1"))
            try db.execute(
                sql: """
                UPDATE sessions
                SET orphan_status = 'suspect',
                    orphan_since = datetime('now'),
                    orphan_reason = 'cleaned_by_source'
                WHERE id = 'recovered'
                """
            )

            let result = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "recovered", snapshotHash: "h1"))

            XCTAssertEqual(result.action, .noop)
            let row = try Row.fetchOne(
                db,
                sql: "SELECT orphan_status, orphan_since, orphan_reason FROM sessions WHERE id = 'recovered'"
            )
            XCTAssertNotNil(row)
            XCTAssertNil(row?["orphan_status"] as String?)
            XCTAssertNil(row?["orphan_since"] as String?)
            XCTAssertNil(row?["orphan_reason"] as String?)
        }
    }

    func testSameContentReindexBackfillsInstructionSignals() throws {
        try writer.write { db in
            let snapshotWriter = SessionSnapshotWriter(db: db)
            _ = try snapshotWriter.writeAuthoritativeSnapshot(makeSnapshot(id: "instruction-backfill", snapshotHash: "h1"))
            try db.execute(sql: "UPDATE session_index_jobs SET status = 'completed' WHERE session_id = 'instruction-backfill'")

            let result = try snapshotWriter.writeAuthoritativeSnapshot(
                makeSnapshot(
                    id: "instruction-backfill",
                    snapshotHash: "h1",
                    instructionCount: 2,
                    humanTurnCount: 2,
                    instructionSummary: "Fix login\nAdd tests"
                )
            )

            XCTAssertEqual(result.action, .merge)
            XCTAssertEqual(result.changeSet.flags, [.localStateChanged])
            let row = try Row.fetchOne(
                db,
                sql: "SELECT instruction_count, human_turn_count, instruction_summary FROM sessions WHERE id = 'instruction-backfill'"
            )
            XCTAssertEqual(row?["instruction_count"] as Int?, 2)
            XCTAssertEqual(row?["human_turn_count"] as Int?, 2)
            XCTAssertEqual(row?["instruction_summary"] as String?, "Fix login\nAdd tests")
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM session_index_jobs WHERE session_id = 'instruction-backfill' AND status = 'pending'"
                ),
                0
            )
        }
    }

    private func makeSnapshot(
        id: String,
        syncVersion: Int = 1,
        snapshotHash: String = "h1",
        sourceLocator: String = "/tmp/rollout.jsonl",
        sizeBytes: Int64 = 128,
        authoritativeNode: String = "node-a",
        startTime: String = "2026-03-18T11:00:00Z",
        summary: String = "hello",
        tier: SessionTier = .normal,
        toolCallCounts: [String: Int] = [:],
        model: String? = "openai",
        parentSessionId: String? = nil,
        tokenUsage: TokenUsage? = nil,
        instructionCount: Int? = nil,
        humanTurnCount: Int? = nil,
        instructionSummary: String? = nil
    ) -> AuthoritativeSessionSnapshot {
        AuthoritativeSessionSnapshot(
            id: id,
            source: .codex,
            authoritativeNode: authoritativeNode,
            syncVersion: syncVersion,
            snapshotHash: snapshotHash,
            indexedAt: "2026-03-18T12:00:00Z",
            sourceLocator: sourceLocator,
            sizeBytes: sizeBytes,
            startTime: startTime,
            endTime: nil,
            cwd: "/repo",
            project: nil,
            model: model,
            messageCount: 2,
            userMessageCount: 1,
            assistantMessageCount: 1,
            toolMessageCount: 0,
            systemMessageCount: 0,
            summary: summary,
            summaryMessageCount: nil,
            instructionCount: instructionCount,
            humanTurnCount: humanTurnCount,
            instructionSummary: instructionSummary,
            origin: nil,
            tier: tier,
            agentRole: nil,
            parentSessionId: parentSessionId,
            toolCallCounts: toolCallCounts,
            tokenUsage: tokenUsage
        )
    }

    private func writeJSONL(_ objects: [[String: Any]], to url: URL) throws {
        let lines = try objects.map { object in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
            return String(data: data, encoding: .utf8)!
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
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

    /// Swift-product-only columns that have no counterpart in the Node reference
    /// golden, so they are excluded from the cross-runtime parity comparison.
    private static let parityExcludedColumns: Set<String> = [
        "offload_state",
        // Swift-side live-session FTS debounce scheduling column; no Node golden counterpart.
        "not_before",
    ]

    private func normalizedRows(_ rows: [Row]) -> [[String: AnyValue]] {
        rows.map { row in
            var output: [String: AnyValue] = [:]
            for column in row.columnNames where !Self.parityExcludedColumns.contains(column) {
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
            return .string(normalizedRepoPath(value))
        case .blob(let data):
            return .string(data.base64EncodedString())
        }
    }

    private func normalizedRepoPath(_ value: String) -> String {
        let rawRoot = repoRoot.deletingLastPathComponent().path
        let resolvedRoot = repoRoot.deletingLastPathComponent().resolvingSymlinksInPath().path
        let roots = Set([rawRoot, resolvedRoot, "/private\(rawRoot)"])
            .sorted { $0.count > $1.count }
        return roots.reduce(value) { normalized, root in
            normalized.replacingOccurrences(of: root, with: "<repo>")
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

private final class ToolRoleSyntheticSessionAdapter: SessionAdapter {
    let source: SourceName = .codex

    func detect() async -> Bool {
        true
    }

    func listSessionLocators() async throws -> [String] {
        ["synthetic://tool-role"]
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .success(
            NormalizedSessionInfo(
                id: "synthetic-tool-role",
                source: .codex,
                startTime: "2026-04-24T00:00:00Z",
                cwd: "/repo",
                model: "synthetic",
                messageCount: 3,
                userMessageCount: 1,
                assistantMessageCount: 1,
                toolMessageCount: 1,
                systemMessageCount: 0,
                summary: "real work",
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
            continuation.yield(NormalizedMessage(role: .user, content: "real work"))
            continuation.yield(NormalizedMessage(role: .tool, content: "tool output"))
            continuation.yield(NormalizedMessage(role: .assistant, content: "done"))
            continuation.finish()
        }
    }

    func isAccessible(locator: String) async -> Bool {
        true
    }
}

private final class BlankAssistantToolCallSyntheticSessionAdapter: SessionAdapter {
    let source: SourceName = .codex

    func detect() async -> Bool {
        true
    }

    func listSessionLocators() async throws -> [String] {
        ["synthetic://blank-assistant-tool-call"]
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .success(
            NormalizedSessionInfo(
                id: "synthetic-blank-assistant-tool-call",
                source: .codex,
                startTime: "2026-04-24T00:00:00Z",
                cwd: "/repo",
                model: "synthetic",
                messageCount: 3,
                userMessageCount: 1,
                assistantMessageCount: 2,
                toolMessageCount: 0,
                systemMessageCount: 0,
                summary: "real work",
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
            continuation.yield(NormalizedMessage(role: .user, content: "real work"))
            continuation.yield(
                NormalizedMessage(
                    role: .assistant,
                    content: "   ",
                    toolCalls: [NormalizedToolCall(name: "Read")]
                )
            )
            continuation.yield(NormalizedMessage(role: .assistant, content: "done"))
            continuation.finish()
        }
    }

    func isAccessible(locator: String) async -> Bool {
        true
    }
}

private final class BlankAssistantNoToolCallSyntheticSessionAdapter: SessionAdapter {
    let source: SourceName = .codex

    func detect() async -> Bool {
        true
    }

    func listSessionLocators() async throws -> [String] {
        ["synthetic://blank-assistant-no-tool-call"]
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .success(
            NormalizedSessionInfo(
                id: "synthetic-blank-assistant-no-tool-call",
                source: .codex,
                startTime: "2026-04-24T00:00:00Z",
                cwd: "/repo",
                model: "synthetic",
                messageCount: 2,
                userMessageCount: 1,
                assistantMessageCount: 1,
                toolMessageCount: 0,
                systemMessageCount: 0,
                summary: "real work",
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
            continuation.yield(NormalizedMessage(role: .user, content: "real work"))
            continuation.yield(NormalizedMessage(role: .assistant, content: "   "))
            continuation.finish()
        }
    }

    func isAccessible(locator: String) async -> Bool {
        true
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
    private let userContent: String
    private let assistantContent: String

    init(
        count: Int,
        userContent: String = "hello",
        assistantContent: String = "done"
    ) {
        self.count = count
        self.userContent = userContent
        self.assistantContent = assistantContent
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
            continuation.yield(NormalizedMessage(role: .user, content: userContent))
            continuation.yield(NormalizedMessage(role: .assistant, content: assistantContent))
            continuation.finish()
        }
    }

    func isAccessible(locator: String) async -> Bool {
        true
    }
}

private final class SyntheticFileSessionAdapter: SessionAdapter {
    let source: SourceName = .claudeCode
    private let locators: [String]

    init(locators: [String]) {
        self.locators = locators
    }

    func detect() async -> Bool {
        true
    }

    func listSessionLocators() async throws -> [String] {
        locators
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        let id = URL(fileURLWithPath: locator).deletingPathExtension().lastPathComponent
        return .success(
            NormalizedSessionInfo(
                id: id,
                source: .claudeCode,
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
        FileManager.default.fileExists(atPath: locator)
    }
}

private final class CountingSyntheticFileSessionAdapter: SessionAdapter {
    let source: SourceName = .codex
    let locator: String
    let listedLocators: [String]
    let sessionId: String
    let userContent: String
    let assistantContent: String
    var streamCount = 0

    init(
        locator: String,
        listedLocators: [String]? = nil,
        sessionId: String = "startup-skip",
        userContent: String = "hello",
        assistantContent: String = "done"
    ) {
        self.locator = locator
        self.listedLocators = listedLocators ?? [locator]
        self.sessionId = sessionId
        self.userContent = userContent
        self.assistantContent = assistantContent
    }

    func detect() async -> Bool {
        true
    }

    func listSessionLocators() async throws -> [String] {
        listedLocators
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .success(
            NormalizedSessionInfo(
                id: sessionId,
                source: source,
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
                sizeBytes: JSONLAdapterSupport.fileSize(locator: locator)
            )
        )
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        streamCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(NormalizedMessage(role: .user, content: userContent))
            continuation.yield(NormalizedMessage(role: .assistant, content: assistantContent))
            continuation.finish()
        }
    }

    func isAccessible(locator: String) async -> Bool {
        FileManager.default.fileExists(atPath: locator)
    }
}

private final class FailingFileSessionAdapter: SessionAdapter {
    let source: SourceName = .codex
    let locator: String
    let failure: ParserFailure
    var parseCount = 0

    init(locator: String, failure: ParserFailure) {
        self.locator = locator
        self.failure = failure
    }

    func detect() async -> Bool {
        true
    }

    func listSessionLocators() async throws -> [String] {
        [locator]
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        parseCount += 1
        return .failure(failure)
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        XCTFail("streamMessages should not be called for parse failures")
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func isAccessible(locator: String) async -> Bool {
        FileManager.default.fileExists(atPath: locator)
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
