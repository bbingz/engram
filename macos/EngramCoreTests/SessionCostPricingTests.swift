import GRDB
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class SessionCostPricingTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-cost-pricing-\(UUID().uuidString).sqlite")
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

    func testClaudePricingNormalizesAliasesSnapshotsAndReasoningSuffixes() {
        assertCost(
            model: " claude-sonnet-4-20250514 ",
            usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 0),
            expected: 3
        )
        assertCost(
            model: "anthropic/CLAUDE-OPUS-4.6-thinking",
            usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 0),
            expected: 5
        )
        assertCost(
            model: "anthropic:claude-haiku-4.5",
            usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 0),
            expected: 1
        )
        assertCost(
            model: "sonnet-4",
            usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 0),
            expected: 3
        )
        assertUnpriced(model: "sonnet")
        assertUnpriced(model: "claude-sonnet-5-0")
    }

    func testGPTPricingNormalizesReasoningSuffixesAndUsesMostSpecificFamily() {
        assertCost(
            model: "gpt-5.1-codex-max-high (high)",
            usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 0),
            expected: 1.25
        )
        assertCost(
            model: "gpt-5.2-codex-medium-low",
            usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 0),
            expected: 1.75
        )
        assertCost(
            model: "gpt-5.4-pro-xhigh",
            usage: TokenUsage(inputTokens: 0, outputTokens: 1_000_000),
            expected: 245.52
        )
        assertUnpriced(model: "gpt-5.1 (turbo)")
        assertUnpriced(model: "gpt-4o (turbo)")
    }

    func testClaudeAggregateSessionCountsKeepBaseRatesAtLongContextVolumes() {
        assertCost(
            model: "claude-sonnet-4-6",
            usage: TokenUsage(inputTokens: 100_000, outputTokens: 0),
            expected: 0.3
        )
        assertCost(
            model: "claude-sonnet-4-6",
            usage: TokenUsage(inputTokens: 200_000, outputTokens: 0),
            expected: 0.6
        )
        assertCost(
            model: "claude-sonnet-4-6",
            usage: TokenUsage(
                inputTokens: 250_000,
                outputTokens: 250_000,
                cacheReadTokens: 250_000,
                cacheCreationTokens: 250_000
            ),
            expected: 5.5125
        )
    }

    func testCodexLongContextTierUsesCumulativeBands() {
        assertCost(
            model: "gpt-5.4",
            usage: TokenUsage(inputTokens: 100_000, outputTokens: 0),
            expected: 0.25
        )
        assertCost(
            model: "gpt-5.4",
            usage: TokenUsage(inputTokens: 272_000, outputTokens: 0),
            expected: 0.68
        )
        assertCost(
            model: "gpt-5.4",
            usage: TokenUsage(inputTokens: 300_000, outputTokens: 300_000, cacheReadTokens: 300_000),
            expected: 5.612
        )
    }

    func testSessionSnapshotWriterStoresNullCostForUnpricedTokenUsage() throws {
        try writer.write { db in
            _ = try SessionSnapshotWriter(db: db).writeAuthoritativeSnapshot(
                makeSnapshot(
                    id: "unknown-model",
                    model: "claude-sonnet-5-0",
                    tokenUsage: TokenUsage(inputTokens: 1_000, outputTokens: 100)
                )
            )

            XCTAssertNil(
                try Double.fetchOne(
                    db,
                    sql: "SELECT cost_usd FROM session_costs WHERE session_id = 'unknown-model'"
                )
            )
        }
    }

    func testBackfillCostsRecomputesAllTokenRowsWhenPricingVersionChanges() throws {
        try writer.write { db in
            try insertSession(db, id: "stale-priced", model: "claude-opus-4-6")
            try insertSession(db, id: "stale-unpriced", model: "claude-sonnet-5-0")
            try db.execute(
                sql: """
                INSERT INTO session_costs(
                  session_id, model, input_tokens, output_tokens, cache_read_tokens,
                  cache_creation_tokens, cost_usd, computed_at
                ) VALUES
                  ('stale-priced', 'claude-opus-4-6', 1000000, 0, 0, 0, 15, '2026-01-01T00:00:00.000Z'),
                  ('stale-unpriced', 'claude-sonnet-5-0', 1000000, 0, 0, 0, 99, '2026-01-01T00:00:00.000Z')
                """
            )
            try db.execute(
                sql: "INSERT INTO metadata(key, value) VALUES ('session_cost_pricing_version', 'legacy')"
            )

            let changed = try StartupBackfills.backfillCosts(db)

            XCTAssertEqual(changed, 2)
            let pricedCost = try XCTUnwrap(
                Double.fetchOne(db, sql: "SELECT cost_usd FROM session_costs WHERE session_id = 'stale-priced'")
            )
            XCTAssertEqual(
                pricedCost,
                5,
                accuracy: 0.000_001
            )
            XCTAssertNil(
                try Double.fetchOne(db, sql: "SELECT cost_usd FROM session_costs WHERE session_id = 'stale-unpriced'")
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'session_cost_pricing_version'"),
                "2"
            )
        }
    }

    private func assertCost(
        model: String,
        usage: TokenUsage,
        expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual: Double? = SessionCostPricing.computeCost(model: model, usage: usage)
        XCTAssertNotNil(actual, file: file, line: line)
        XCTAssertEqual(actual ?? .nan, expected, accuracy: 0.000_001, file: file, line: line)
    }

    private func assertUnpriced(
        model: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual: Double? = SessionCostPricing.computeCost(
            model: model,
            usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000)
        )
        XCTAssertNil(actual, file: file, line: line)
    }

    private func insertSession(_ db: Database, id: String, model: String) throws {
        try db.execute(
            sql: """
            INSERT INTO sessions(id, source, start_time, end_time, cwd, file_path, model, tier)
            VALUES (?, 'codex', '2026-04-23T10:00:00.000Z', '2026-04-23T11:00:00.000Z', '/repo', '/tmp/session.jsonl', ?, 'normal')
            """,
            arguments: [id, model]
        )
    }

    private func makeSnapshot(
        id: String,
        model: String?,
        tokenUsage: TokenUsage
    ) -> AuthoritativeSessionSnapshot {
        AuthoritativeSessionSnapshot(
            id: id,
            source: .codex,
            authoritativeNode: "node-a",
            syncVersion: 1,
            snapshotHash: "h1",
            indexedAt: "2026-03-18T12:00:00Z",
            sourceLocator: "/tmp/rollout.jsonl",
            sizeBytes: 128,
            startTime: "2026-03-18T11:00:00Z",
            endTime: nil,
            cwd: "/repo",
            project: nil,
            model: model,
            messageCount: 2,
            userMessageCount: 1,
            assistantMessageCount: 1,
            toolMessageCount: 0,
            systemMessageCount: 0,
            summary: "hello",
            summaryMessageCount: nil,
            instructionCount: nil,
            humanTurnCount: nil,
            instructionSummary: nil,
            origin: nil,
            tier: .normal,
            agentRole: nil,
            parentSessionId: nil,
            toolCallCounts: [:],
            tokenUsage: tokenUsage
        )
    }
}
