import GRDB
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class StartupBackfillTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-backfills-\(UUID().uuidString).sqlite")
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

    func testDowngradeSubagentTiersAndRemoveFTSRows() throws {
        try writer.write { db in
            try insertSession(db, id: "subagent-1", source: "codex", agentRole: "subagent", tier: "lite")
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('subagent-1', 'hidden')")

            let changed = try StartupBackfills.downgradeSubagentTiers(db)
            XCTAssertEqual(changed, 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'subagent-1'"), "skip")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'subagent-1'"), 0)
        }
    }

    func testDowngradeSubagentTiersPurgesFtsMapArtifacts_repro() throws {
        try writer.write { db in
            let leaked = "purge-leak-subagent-downgrade"
            let kept = "purge-keep-subagent-downgrade"
            try insertSession(db, id: "subagent-1", source: "codex", agentRole: "subagent", tier: "lite")
            try insertSession(db, id: "normal-1", source: "codex", tier: "normal")
            try createRecoverableArtifactTables(db)
            try insertRecoverableArtifacts(db, sessionId: "subagent-1", content: leaked)
            try insertRecoverableArtifacts(db, sessionId: "normal-1", content: kept)

            // PR #141 regression: batch skip cleanup must purge fts_map rows as
            // well as cached messages, FTS, and embedding artifacts.
            let changed = try StartupBackfills.downgradeSubagentTiers(db)

            XCTAssertEqual(changed, 1)
            try assertRecoverableArtifactContent(db, content: leaked, expectedCount: 0)
            try assertRecoverableArtifactContent(db, content: kept, expectedCount: 4)
        }
    }

    func testBackfillParentLinksUsesPathAndPreservesManualLinks() throws {
        try writer.write { db in
            try insertSession(db, id: "parent-1", source: "codex", tier: "normal")
            try insertSession(
                db,
                id: "child-1",
                source: "codex",
                filePath: "/tmp/parent-1/subagents/worker.jsonl",
                agentRole: "subagent",
                tier: "skip",
                suggestionStatus: "ambiguous",
                suggestionCandidates: "[{\"id\":\"old\",\"score\":0.91}]"
            )
            try insertSession(
                db,
                id: "manual-child",
                source: "codex",
                filePath: "/tmp/parent-1/subagents/manual.jsonl",
                agentRole: "subagent",
                tier: "skip",
                linkSource: "manual"
            )

            let result = try StartupBackfills.backfillParentLinks(db)
            XCTAssertEqual(result.linked, 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child-1'"),
                "parent-1"
            )
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT suggestion_status FROM sessions WHERE id = 'child-1'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT suggestion_candidates FROM sessions WHERE id = 'child-1'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'manual-child'"))
        }
    }

    func testRunPeriodicParentBackfillsLinksAgentChildren() throws {
        try writer.write { db in
            try insertSession(db, id: "parent-1", source: "codex", tier: "normal")
            try insertSession(
                db,
                id: "child-1",
                source: "codex",
                filePath: "/tmp/parent-1/subagents/worker.jsonl",
                agentRole: "subagent",
                tier: "skip"
            )
        }

        // idx-1: the periodic indexing loop must run parent detection so a
        // freshly indexed subagent child is grouped under its parent without
        // waiting for a service restart.
        try writer.runPeriodicParentBackfills()

        try writer.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child-1'"),
                "parent-1"
            )
        }
    }

    func testResetStaleDetectionsStoresVersionAndSkipsManualLinks() throws {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO metadata(key, value) VALUES ('detection_version', '3')")
            try insertSession(
                db,
                id: "stale",
                source: "gemini-cli",
                linkCheckedAt: "2026-01-01T00:00:00Z"
            )
            try insertSession(
                db,
                id: "manual",
                source: "gemini-cli",
                linkSource: "manual",
                linkCheckedAt: "2026-01-01T00:00:00Z"
            )
            try insertSession(
                db,
                id: "ambiguous",
                source: "codex",
                linkCheckedAt: "2026-01-01T00:00:00Z",
                suggestionStatus: "ambiguous",
                suggestionCandidates: "[{\"id\":\"p1\",\"score\":0.91}]"
            )

            let reset = try StartupBackfills.resetStaleDetections(db)
            XCTAssertEqual(reset, 2)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'stale'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'ambiguous'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT suggestion_status FROM sessions WHERE id = 'ambiguous'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT suggestion_candidates FROM sessions WHERE id = 'ambiguous'"))
            XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'manual'"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'detection_version'"),
                "\(ParentDetection.detectionVersion)"
            )
        }
    }

    /// D01 (wave-6 task 4 / multi-expert audit 2026-06-10): phase-1
    /// `indexSessions(runParentBackfills:)` used to run suggested-parent
    /// heuristics before Layer-1b originator. The originator query excludes
    /// rows with `suggested_parent_id` set, so a Codex session with
    /// originator "Claude Code" that also scores a heuristic parent was
    /// permanently blocked from `agent_role=dispatched` / tier=skip — periodic
    /// cycles do not clear the suggestion, so they do not self-heal.
    func testCodexOriginatorBlockedWhenSuggestedParentAssignedFirst_repro() throws {
        let codexFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-d01-originator-\(UUID().uuidString).jsonl")
        try #"{"type":"session_meta","payload":{"id":"codex-d01","originator":"Claude Code"}}"#
            .appending("\n")
            .write(to: codexFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: codexFile) }

        try writer.write { db in
            try insertSession(
                db,
                id: "parent-d01",
                source: "claude-code",
                startTime: "2026-04-23T10:05:00.000Z",
                endTime: nil,
                cwd: "/Users/bing/-Code-/engram",
                project: "engram"
            )
            try insertSession(
                db,
                id: "codex-d01",
                source: "codex",
                startTime: "2026-04-23T10:10:00.000Z",
                cwd: "/Users/bing/-Code-/engram",
                project: "engram",
                summary: "Your task is to audit the repo",
                filePath: codexFile.path
            )

            // Old inverted order: heuristics first.
            let suggestions = try StartupBackfills.backfillSuggestedParents(db)
            XCTAssertEqual(suggestions.suggested, 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'codex-d01'"),
                "parent-d01"
            )

            let originatorUpdated = try StartupBackfills.backfillCodexOriginator(db)
            XCTAssertEqual(originatorUpdated, 0, "originator must skip rows with suggested_parent_id set")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'codex-d01'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'codex-d01'"))

            // Periodic re-run does not self-heal: originator still excludes the row.
            XCTAssertEqual(try StartupBackfills.backfillCodexOriginator(db), 0)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'codex-d01'"))
        }
    }

    func testCodexOriginatorRunsBeforeSuggestedParentsAndClassifies_repro() throws {
        let codexFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-d01-order-\(UUID().uuidString).jsonl")
        try #"{"type":"session_meta","payload":{"id":"codex-d01b","originator":"Claude Code"}}"#
            .appending("\n")
            .write(to: codexFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: codexFile) }

        try writer.write { db in
            try insertSession(
                db,
                id: "parent-d01b",
                source: "claude-code",
                startTime: "2026-04-23T10:05:00.000Z",
                endTime: nil,
                cwd: "/Users/bing/-Code-/engram",
                project: "engram"
            )
            try insertSession(
                db,
                id: "codex-d01b",
                source: "codex",
                startTime: "2026-04-23T10:10:00.000Z",
                cwd: "/Users/bing/-Code-/engram",
                project: "engram",
                summary: "Your task is to audit the repo",
                filePath: codexFile.path
            )

            // Correct order (matches fixed indexSessions / periodic path).
            XCTAssertEqual(try StartupBackfills.backfillCodexOriginator(db), 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'codex-d01b'"),
                "dispatched"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'codex-d01b'"),
                "skip"
            )

            // Suggested-parent scoring may still run, but Layer-1b classification
            // already landed and must not be undone by heuristics.
            _ = try StartupBackfills.backfillSuggestedParents(db)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'codex-d01b'"),
                "dispatched"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'codex-d01b'"),
                "skip"
            )
        }
    }

    func testBackfillCodexOriginatorMarksClaudeLaunchedCodexSessions() throws {
        let codexFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-originator-\(UUID().uuidString).jsonl")
        let nativeCodexFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-native-originator-\(UUID().uuidString).jsonl")
        try #"{"type":"session_meta","payload":{"id":"codex-1","originator":"Claude Code"}}"#
            .appending("\n")
            .write(to: codexFile, atomically: true, encoding: .utf8)
        try #"{"type":"session_meta","payload":{"id":"codex-2","originator":"Codex CLI"}}"#
            .appending("\n")
            .write(to: nativeCodexFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: codexFile) }
        defer { try? FileManager.default.removeItem(at: nativeCodexFile) }

        try writer.write { db in
            try insertSession(db, id: "codex-1", source: "codex", filePath: codexFile.path)
            try insertSession(db, id: "codex-2", source: "codex", filePath: nativeCodexFile.path)

            let updated = try StartupBackfills.backfillCodexOriginator(db)
            XCTAssertEqual(updated, 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'codex-1'"), "dispatched")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'codex-1'"), "skip")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'codex-2'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'codex-2'"))
            XCTAssertNotNil(
                try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'codex-2'"),
                "Ordinary Codex sessions must be marked inspected so the startup backfill candidate set drains."
            )
        }
    }

    func testBackfillCodexOriginatorPurgesLegacyMessageArtifacts_repro() throws {
        let codexFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-originator-purge-\(UUID().uuidString).jsonl")
        try #"{"type":"session_meta","payload":{"id":"codex-claude","originator":"Claude Code"}}"#
            .appending("\n")
            .write(to: codexFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: codexFile) }

        try writer.write { db in
            let leaked = "purge-leak-codex-originator"
            let kept = "purge-keep-codex-originator"
            try insertSession(db, id: "codex-claude", source: "codex", filePath: codexFile.path, tier: "normal")
            try insertSession(db, id: "codex-native", source: "codex", tier: "normal")
            try createRecoverableArtifactTables(db)
            try insertRecoverableArtifacts(db, sessionId: "codex-claude", content: leaked)
            try insertRecoverableArtifacts(db, sessionId: "codex-native", content: kept)

            // PR #141 regression: per-session skip classification must purge
            // legacy cached message rows as well as FTS and embedding artifacts.
            let updated = try StartupBackfills.backfillCodexOriginator(db)

            XCTAssertEqual(updated, 1)
            try assertRecoverableArtifactContent(db, content: leaked, expectedCount: 0)
            try assertRecoverableArtifactContent(db, content: kept, expectedCount: 4)
        }
    }

    func testBackfillCodexOriginatorDrainsLargeOrdinaryBatchBeforeClaudeOriginatedRows() throws {
        let nativeCodexFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-native-originator-\(UUID().uuidString).jsonl")
        let claudeCodexFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-claude-originator-\(UUID().uuidString).jsonl")
        try #"{"type":"session_meta","payload":{"id":"codex-native","originator":"Codex CLI"}}"#
            .appending("\n")
            .write(to: nativeCodexFile, atomically: true, encoding: .utf8)
        try #"{"type":"session_meta","payload":{"id":"codex-claude","originator":"Claude Code"}}"#
            .appending("\n")
            .write(to: claudeCodexFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: nativeCodexFile) }
        defer { try? FileManager.default.removeItem(at: claudeCodexFile) }

        try writer.write { db in
            for index in 0..<501 {
                try insertSession(
                    db,
                    id: "native-\(index)",
                    source: "codex",
                    filePath: nativeCodexFile.path
                )
            }
            try insertSession(db, id: "claude-late", source: "codex", filePath: claudeCodexFile.path)

            XCTAssertEqual(try StartupBackfills.backfillCodexOriginator(db), 1)

            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'claude-late'"),
                "dispatched"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'claude-late'"),
                "skip"
            )
        }
    }

    func testBackfillCodexModelLabelsRelabelsTargetsAndLeavesNonCodexRowsUntouched() throws {
        let openAIToReal = try writeCodexRollout(
            id: "openai-real",
            turnContextModel: "gpt-5.5",
            modelProvider: "openai"
        )
        let openAIToNull = try writeCodexRollout(id: "openai-null", modelProvider: "openai")
        let nullToReal = try writeCodexRollout(id: "null-real", responseItemModel: "gpt-5.4")
        let nonCodex = try writeCodexRollout(id: "non-codex", turnContextModel: "gpt-5.5")
        defer {
            try? FileManager.default.removeItem(at: openAIToReal)
            try? FileManager.default.removeItem(at: openAIToNull)
            try? FileManager.default.removeItem(at: nullToReal)
            try? FileManager.default.removeItem(at: nonCodex)
        }

        try writer.write { db in
            try insertSession(db, id: "openai-real", source: "codex", filePath: openAIToReal.path, model: "openai")
            try insertSession(db, id: "openai-null", source: "codex", filePath: openAIToNull.path, model: "openai")
            try insertSession(db, id: "null-real", source: "codex", filePath: nullToReal.path)
            try insertSession(db, id: "non-codex", source: "claude-code", filePath: nonCodex.path, model: "openai")

            let updated = try StartupBackfills.backfillCodexModelLabels(db)

            XCTAssertEqual(updated, 3)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT model FROM sessions WHERE id = 'openai-real'"), "gpt-5.5")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT model FROM sessions WHERE id = 'openai-null'"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT model FROM sessions WHERE id = 'null-real'"), "gpt-5.4")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT model FROM sessions WHERE id = 'non-codex'"), "openai")
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'codex_model_backfill_version'"),
                "1"
            )
        }
    }

    func testBackfillCodexModelLabelsVersionGatePreventsSecondScan() throws {
        let rollout = try writeCodexRollout(id: "version-gated", turnContextModel: "gpt-5.5")
        defer { try? FileManager.default.removeItem(at: rollout) }

        try writer.write { db in
            try insertSession(db, id: "version-gated", source: "codex", filePath: rollout.path, model: "openai")

            XCTAssertEqual(try StartupBackfills.backfillCodexModelLabels(db), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT model FROM sessions WHERE id = 'version-gated'"), "gpt-5.5")

            try db.execute(sql: "UPDATE sessions SET model = 'openai' WHERE id = 'version-gated'")
            XCTAssertEqual(try StartupBackfills.backfillCodexModelLabels(db), 0)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT model FROM sessions WHERE id = 'version-gated'"), "openai")
        }
    }

    func testCodexModelBackfillRunsBeforeCostBackfillAndRecomputesRelabeledCost() throws {
        let rollout = try writeCodexRollout(id: "cost-relabel", turnContextModel: "gpt-5.5")
        defer { try? FileManager.default.removeItem(at: rollout) }

        try writer.write { db in
            try insertSession(db, id: "cost-relabel", source: "codex", filePath: rollout.path, model: "openai")
            try db.execute(
                sql: """
                INSERT INTO session_costs(
                  session_id, model, input_tokens, output_tokens, cache_read_tokens,
                  cache_creation_tokens, cost_usd, computed_at
                ) VALUES ('cost-relabel', NULL, 1000000, 100000, 0, 0, NULL, '2026-01-01T00:00:00.000Z')
                """
            )

            XCTAssertEqual(try StartupBackfills.backfillCodexModelLabels(db), 1)
            XCTAssertEqual(try StartupBackfills.backfillCosts(db), 1)

            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT model FROM sessions WHERE id = 'cost-relabel'"), "gpt-5.5")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT model FROM session_costs WHERE session_id = 'cost-relabel'"), "gpt-5.5")
            XCTAssertNotNil(try Double.fetchOne(db, sql: "SELECT cost_usd FROM session_costs WHERE session_id = 'cost-relabel'"))
        }
    }

    func testBackfillPolycliProviderParentsClassifiesPingProbes() throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "host-codex",
                source: "codex",
                startTime: "2026-05-08T09:00:00.000Z",
                endTime: "2026-05-08T10:20:00.000Z",
                cwd: "/repo"
            )
            try insertSession(
                db,
                id: "qwen-ping",
                source: "qwen",
                startTime: "2026-05-08T10:00:00.000Z",
                cwd: "/repo",
                summary: "ping"
            )
            try insertSession(
                db,
                id: "opencode-ping",
                source: "opencode",
                startTime: "2026-05-08T10:00:30.000Z",
                cwd: "/repo",
                summary: "Quick ping"
            )

            let result = try StartupBackfills.backfillPolycliProviderParents(db)

            XCTAssertEqual(result, StartupBackfills.ProviderParentResult(checked: 2, classified: 2, linked: 0, suggested: 2))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'qwen-ping'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'opencode-ping'"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'qwen-ping'"),
                "host-codex"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'opencode-ping'"),
                "host-codex"
            )
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = 'qwen-ping'"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'qwen-ping'"), "dispatched")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'opencode-ping'"), "skip")
        }
    }

    func testBackfillPolycliProviderParentsClassifiesReviewProbes() throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "host-codex",
                source: "codex",
                startTime: "2026-05-08T09:00:00.000Z",
                endTime: "2026-05-08T11:00:00.000Z",
                cwd: "/repo"
            )
            try insertSession(
                db,
                id: "qwen-review",
                source: "qwen",
                startTime: "2026-05-08T10:00:00.000Z",
                cwd: "/repo",
                summary: "No tools. Review P7.10 Stage 2 diff for blocking correctness issues. Tests passed."
            )
            try insertSession(
                db,
                id: "kimi-review",
                source: "kimi",
                startTime: "2026-05-08T10:00:01.000Z",
                summary: "Use only snippets. P7.4 final review. Report only blocking/correctness issues."
            )
            try insertSession(
                db,
                id: "qwen-stage-facts",
                source: "qwen",
                startTime: "2026-05-08T10:00:02.000Z",
                cwd: "/repo",
                summary: "No tools. Stage 3 adapter facts: planned Graylog query, stream filter, timeout."
            )
            try insertSession(
                db,
                id: "qwen-concurrent",
                source: "qwen",
                startTime: "2026-05-08T09:00:03.000Z",
                cwd: "/repo",
                summary: "请做一次 UI 一致性审查，聚焦保存按钮。"
            )
            try insertSession(
                db,
                id: "qwen-standalone",
                source: "qwen",
                startTime: "2026-05-08T09:10:00.000Z",
                cwd: "/repo",
                summary: "What does this function do?"
            )

            let result = try StartupBackfills.backfillPolycliProviderParents(db)

            // Wave 7B M18: ordinary concurrent same-cwd sessions are no longer
            // classified without probe/dispatch summary evidence.
            XCTAssertGreaterThanOrEqual(result.classified, 3)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'qwen-review'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'qwen-stage-facts'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'qwen-concurrent'"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'qwen-review'"),
                "host-codex"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'qwen-stage-facts'"),
                "host-codex"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'qwen-concurrent'"),
                "ordinary concurrent session must not be auto-linked without probe summary"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'kimi-review'")
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'kimi-review'"), "skip")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'qwen-standalone'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'qwen-concurrent'"))
        }
    }

    func testBackfillPolycliProviderParentsLeavesGenuineClaudeCodeReviewAlone() throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "host-codex",
                source: "codex",
                startTime: "2026-05-08T09:00:00.000Z",
                endTime: "2026-05-08T11:00:00.000Z",
                cwd: "/repo"
            )
            // A genuine claude-code session that merely mentions "review" must stay
            // a top-level session, not be classified as a dispatched provider child.
            try insertSession(
                db,
                id: "cc-review",
                source: "claude-code",
                startTime: "2026-05-08T10:00:00.000Z",
                cwd: "/repo",
                summary: "Please review the auth refactor and update the review checklist."
            )

            let result = try StartupBackfills.backfillPolycliProviderParents(db)
            XCTAssertEqual(result.classified, 0, "claude-code review session must not be classified")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'cc-review'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'cc-review'"))
        }
    }

    func testBackfillPolycliProviderParentsSkipsAlreadyCheckedCandidates() throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "host-codex",
                source: "codex",
                startTime: "2026-05-08T09:00:00.000Z",
                endTime: "2026-05-08T11:00:00.000Z",
                cwd: "/repo"
            )
            try insertSession(
                db,
                id: "qwen-linked",
                source: "qwen",
                startTime: "2026-05-08T10:00:00.000Z",
                cwd: "/repo",
                summary: "ping"
            )
            try insertSession(
                db,
                id: "kimi-unlinked",
                source: "kimi",
                startTime: "2026-05-08T10:00:01.000Z",
                summary: "Use only snippets. P7.4 final review. Report only blocking/correctness issues."
            )
            try insertSession(
                db,
                id: "qwen-ordinary",
                source: "qwen",
                startTime: "2026-05-08T09:10:00.000Z",
                cwd: "/repo",
                summary: "What does this function do?"
            )

            let first = try StartupBackfills.backfillPolycliProviderParents(db)
            let second = try StartupBackfills.backfillPolycliProviderParents(db)

            XCTAssertEqual(first, StartupBackfills.ProviderParentResult(checked: 2, classified: 2, linked: 0, suggested: 1))
            XCTAssertEqual(second, StartupBackfills.ProviderParentResult(checked: 0, classified: 0, linked: 0))
            XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'qwen-linked'"))
            XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'kimi-unlinked'"))
            XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'qwen-ordinary'"))
        }
    }

    func testBackfillSuggestedParentsScoresClaudeParentsAndMarksOrphans() throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "parent",
                source: "claude-code",
                startTime: "2026-04-23T10:00:00.000Z",
                endTime: nil,
                cwd: "/Users/bing/-Code-/engram",
                project: "engram"
            )
            try insertSession(
                db,
                id: "agent",
                source: "gemini-cli",
                startTime: "2026-04-23T10:10:00.000Z",
                cwd: "/Users/bing/-Code-/engram",
                project: "engram",
                summary: "Your task is to review the adapter implementation"
            )
            try insertSession(
                db,
                id: "ordinary",
                source: "gemini-cli",
                startTime: "2026-04-23T10:12:00.000Z",
                summary: "What does this function do?"
            )
            try insertSession(
                db,
                id: "orphan",
                source: "codex",
                startTime: "2026-04-23T09:00:00.000Z",
                summary: "Your task is to audit the repo",
                agentRole: "dispatched"
            )

            let result = try StartupBackfills.backfillSuggestedParents(db)
            XCTAssertEqual(result.checked, 3)
            XCTAssertEqual(result.suggested, 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'agent'"),
                "parent"
            )
            XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'ordinary'"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'orphan'"), "dispatched")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'orphan'"), "skip")
        }
    }

    func testBackfillSuggestedParentsWritesAmbiguousCandidatesWithoutSkipping() throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "parent-a",
                source: "claude-code",
                startTime: "2026-04-23T10:00:00.000Z",
                endTime: nil,
                cwd: "/Users/bing/-Code-/engram",
                project: "engram"
            )
            try insertSession(
                db,
                id: "parent-b",
                source: "claude-code",
                startTime: "2026-04-23T10:01:00.000Z",
                endTime: nil,
                cwd: "/Users/bing/-Code-/engram",
                project: "engram"
            )
            try insertSession(
                db,
                id: "agent",
                source: "codex",
                startTime: "2026-04-23T10:10:00.000Z",
                cwd: "/Users/bing/-Code-/engram",
                project: "engram",
                summary: "Your task is to audit the repo",
                agentRole: "dispatched",
                tier: "skip"
            )

            let result = try StartupBackfills.backfillSuggestedParents(db)

            XCTAssertEqual(result.checked, 1)
            XCTAssertEqual(result.suggested, 0)
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT suggested_parent_id, suggestion_status, suggestion_candidates,
                       agent_role, tier, link_checked_at
                FROM sessions
                WHERE id = 'agent'
            """))
            XCTAssertNil(row["suggested_parent_id"] as String?)
            XCTAssertEqual(row["suggestion_status"] as String?, "ambiguous")
            // Wave 7B H04: keep dispatched/skip so top-level lists stay clean.
            XCTAssertEqual(row["agent_role"] as String?, "dispatched")
            XCTAssertEqual(row["tier"] as String?, "skip")
            XCTAssertNotNil(row["link_checked_at"] as String?)

            let encoded = try XCTUnwrap(row["suggestion_candidates"] as String?)
            let candidates = try JSONDecoder().decode([StoredAmbiguousCandidate].self, from: Data(encoded.utf8))
            XCTAssertEqual(candidates.map(\.id), ["parent-b", "parent-a"])
            XCTAssertEqual(candidates.count, 2)
        }
    }

    func testBackfillSuggestedParentsClearsAmbiguousStateWhenReevaluationFindsSuggestion() throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "best-parent",
                source: "claude-code",
                startTime: "2026-04-23T10:05:00.000Z",
                endTime: nil,
                cwd: "/Users/bing/-Code-/engram",
                project: "engram"
            )
            try insertSession(
                db,
                id: "weak-parent",
                source: "claude-code",
                startTime: "2026-04-22T11:00:00.000Z",
                endTime: nil,
                cwd: "/Users/bing/-Code-/engram",
                project: "engram"
            )
            try insertSession(
                db,
                id: "agent",
                source: "gemini-cli",
                startTime: "2026-04-23T10:10:00.000Z",
                cwd: "/Users/bing/-Code-/engram",
                project: "engram",
                summary: "Your task is to audit the repo",
                suggestionStatus: "ambiguous",
                suggestionCandidates: "[{\"id\":\"old\",\"score\":0.91}]"
            )

            let result = try StartupBackfills.backfillSuggestedParents(db)

            XCTAssertEqual(result.checked, 1)
            XCTAssertEqual(result.suggested, 1)
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT suggested_parent_id, suggestion_status, suggestion_candidates
                FROM sessions
                WHERE id = 'agent'
            """))
            XCTAssertEqual(row["suggested_parent_id"] as String?, "best-parent")
            XCTAssertNil(row["suggestion_status"] as String?)
            XCTAssertNil(row["suggestion_candidates"] as String?)
        }
    }

    func testBackfillSuggestedParentsKeepsBatchParentsWithinCandidateLookback() throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "stale-parent",
                source: "claude-code",
                startTime: "2026-04-23T10:00:00.000Z",
                endTime: nil,
                cwd: "/Users/bing/-Code-/engram",
                project: "engram"
            )
            try insertSession(
                db,
                id: "early-agent",
                source: "gemini-cli",
                startTime: "2026-04-23T10:10:00.000Z",
                cwd: "/Users/bing/-Code-/engram",
                project: "engram",
                summary: "Your task is to review the adapter implementation"
            )
            try insertSession(
                db,
                id: "late-agent",
                source: "gemini-cli",
                startTime: "2026-04-26T10:10:00.000Z",
                cwd: "/Users/bing/-Code-/engram",
                project: "engram",
                summary: "Your task is to review the adapter implementation"
            )

            let result = try StartupBackfills.backfillSuggestedParents(db)

            XCTAssertEqual(result.checked, 2)
            XCTAssertEqual(result.suggested, 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'early-agent'"),
                "stale-parent"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'late-agent'"),
                "A globally fetched parent outside the candidate's 24h lookback must not be scored."
            )
            XCTAssertNotNil(
                try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'late-agent'")
            )
        }
    }

    func testRunInitialScanEmitsNodeCompatibleStartupEventsInOrder() async throws {
        let indexer = RecordingStartupIndexer(indexed: 7, countBackfilled: 2, costBackfilled: 3)
        let database = RecordingStartupDatabase()
        let jobRunner = RecordingStartupIndexJobRunner()
        let usageCollector = RecordingStartupUsageCollector()
        let orphanScanner = RecordingStartupOrphanScanner()
        let logger = RecordingStartupLogger()
        var events: [StartupBackfillEvent] = []

        try await StartupBackfills.runInitialScan(
            emit: { events.append($0) },
            log: logger,
            usageCollector: usageCollector,
            indexer: indexer,
            indexJobRunner: jobRunner,
            database: database,
            orphanScanner: orphanScanner
        )

        XCTAssertEqual(
            database.callOrder,
            [
                "backfillCodexModelLabels",
                "backfillScores",
                "deduplicateFilePaths",
                "optimizeFts",
                "vacuumIfNeeded",
                "reconcileInsights",
                "reconcileGroupedSourceDirs",
                "backfillFilePaths",
                "downgradeSubagentTiers",
                "backfillParentLinks",
                "resetStaleDetections",
                "backfillCodexOriginator",
                "backfillPolycliProviderParents",
                "backfillSuggestedParents",
                "cleanupStaleMigrations",
                "countSessions",
                "countTodayParentSessions",
                "enqueueStaleFtsJobs",
                "reconcileSkipTierIndexArtifacts",
                "pruneIndexJobs"
            ]
        )
        XCTAssertEqual(
            events,
            [
                StartupBackfillEvent(event: "backfill_counts", payload: ["backfilled": .int(2)]),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("codex_model_labels"), "updated": .int(30)]),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("costs"), "count": .int(3)]),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("scores"), "count": .int(4)]),
                StartupBackfillEvent(event: "db_maintenance", payload: ["action": .string("dedup"), "removed": .int(5)]),
                StartupBackfillEvent(event: "db_maintenance", payload: ["action": .string("vacuum")]),
                StartupBackfillEvent(
                    event: "db_maintenance",
                    payload: [
                        "action": .string("reconcile_insights"),
                        "resetEmbedding": .int(6),
                        "orphanedVector": .int(7)
                    ]
                ),
                StartupBackfillEvent(
                    event: "db_maintenance",
                    payload: [
                        "action": .string("reconcile_grouped_dirs"),
                        "scanned": .int(30),
                        "planned": .int(31),
                        "applied": .int(32),
                        "collisions": .int(33),
                        "ambiguous": .int(34),
                        "issues": .int(35)
                    ]
                ),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("file_paths"), "count": .int(8)]),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("subagent_tier_downgrade"), "count": .int(9)]),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("parent_links"), "linked": .int(10)]),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("detection_reset"), "count": .int(11)]),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("codex_originator"), "updated": .int(12)]),
                StartupBackfillEvent(
                    event: "backfill",
                    payload: [
                        "type": .string("polycli_provider_parents"),
                        "checked": .int(26),
                        "classified": .int(27),
                        "linked": .int(28),
                        "suggested": .int(29)
                    ]
                ),
                StartupBackfillEvent(
                    event: "backfill",
                    payload: [
                        "type": .string("suggested_parents"),
                        "checked": .int(13),
                        "suggested": .int(14)
                    ]
                ),
                StartupBackfillEvent(event: "migration_cleanup", payload: ["stale": .int(15)]),
                StartupBackfillEvent(
                    event: "ready",
                    payload: ["indexed": .int(7), "total": .int(16), "todayParents": .int(17)]
                ),
                StartupBackfillEvent(
                    event: "orphan_scan",
                    payload: [
                        "scanned": .int(18),
                        "newly_flagged": .int(19),
                        "confirmed": .int(20),
                        "recovered": .int(21),
                        "skipped": .int(22)
                    ]
                ),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("stale_fts_jobs"), "count": .int(29)]),
                StartupBackfillEvent(
                    event: "index_jobs_recovered",
                    payload: ["completed": .int(23), "notApplicable": .int(24)]
                ),
                StartupBackfillEvent(event: "insights_promoted", payload: ["count": .int(25)])
            ]
        )
        XCTAssertTrue(usageCollector.didStart)
        XCTAssertTrue(logger.warnings.isEmpty)
    }

    func testRunInitialScanKeepsReadyWhenRecoverableBackfillsFail() async throws {
        let database = RecordingStartupDatabase()
        database.backfillScoresError = TestError.expected
        database.filePathBackfillError = TestError.expected
        var events: [StartupBackfillEvent] = []

        try await StartupBackfills.runInitialScan(
            emit: { events.append($0) },
            log: RecordingStartupLogger(),
            usageCollector: RecordingStartupUsageCollector(),
            indexer: RecordingStartupIndexer(indexed: 1),
            indexJobRunner: RecordingStartupIndexJobRunner(completed: 0, notApplicable: 0, promoted: 0),
            database: database,
            orphanScanner: RecordingStartupOrphanScanner(newlyFlagged: 0, confirmed: 0, recovered: 0),
            adapters: []
        )

        XCTAssertEqual(events.map(\.event).filter { $0 == "ready" }.count, 1)
        XCTAssertTrue(events.contains(StartupBackfillEvent(event: "error", payload: ["message": .string("backfillFilePaths: expected")])))
    }

    func testInlineCountAndCostBackfillsEmitProgressEvents() async throws {
        let indexer = RecordingStartupIndexer(indexed: 1)
        indexer.usesInlineCountAndCostBackfills = true
        let database = RecordingStartupDatabase()
        var events: [StartupBackfillEvent] = []

        try await StartupBackfills.runStartupMaintenanceAndParents(
            indexed: 1,
            emit: { events.append($0) },
            log: RecordingStartupLogger(),
            indexer: indexer,
            database: database
        )

        XCTAssertTrue(events.contains(StartupBackfillEvent(event: "backfill_inline", payload: ["type": .string("counts")])))
        XCTAssertTrue(events.contains(StartupBackfillEvent(event: "backfill_inline", payload: ["type": .string("costs")])))
    }

    func testStartupMaintenanceRethrowsCancellationFromAsyncBackfills() async throws {
        let indexer = RecordingStartupIndexer(indexed: 1)
        indexer.countBackfillError = CancellationError()

        do {
            try await StartupBackfills.runStartupMaintenanceAndParents(
                indexed: 1,
                emit: { _ in },
                log: RecordingStartupLogger(),
                indexer: indexer,
                database: RecordingStartupDatabase()
            )
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }

    func testStartupOrphanScanRethrowsCancellation() async throws {
        let scanner = RecordingStartupOrphanScanner()
        scanner.error = CancellationError()

        do {
            try await StartupBackfills.runStartupOrphanScan(
                emit: { _ in },
                log: RecordingStartupLogger(),
                orphanScanner: scanner,
                database: RecordingStartupDatabase(),
                adapters: []
            )
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }

    func testStartupIndexJobDrainRethrowsCancellation() async throws {
        let runner = RecordingStartupIndexJobRunner()
        runner.recoverError = CancellationError()

        do {
            try await StartupBackfills.drainStartupIndexJobs(
                emit: { _ in },
                log: RecordingStartupLogger(),
                usageCollector: RecordingStartupUsageCollector(),
                indexJobRunner: runner
            )
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }

    func testBackfillCostsComputesKnownModelZeroCostRows() throws {
        try writer.write { db in
            try insertSession(db, id: "cost-backfill", source: "claude-code", tier: "normal")
            try db.execute(
                sql: "UPDATE sessions SET model = 'claude-sonnet-4-6' WHERE id = 'cost-backfill'"
            )
            try db.execute(
                sql: """
                INSERT INTO session_costs(
                  session_id, model, input_tokens, output_tokens, cache_read_tokens,
                  cache_creation_tokens, cost_usd, computed_at
                ) VALUES ('cost-backfill', 'claude-sonnet-4-6', 1000000, 100000, 500000, 10000, 0, '2026-01-01T00:00:00.000Z')
                """
            )

            let changed = try StartupBackfills.backfillCosts(db)

            XCTAssertEqual(changed, 1)
            XCTAssertEqual(
                try XCTUnwrap(Double.fetchOne(db, sql: "SELECT cost_usd FROM session_costs WHERE session_id = 'cost-backfill'")),
                4.6875,
                accuracy: 0.000_001
            )
            XCTAssertNotEqual(
                try String.fetchOne(db, sql: "SELECT computed_at FROM session_costs WHERE session_id = 'cost-backfill'"),
                "2026-01-01T00:00:00.000Z"
            )
        }
    }

    func testBackfillFilePathsUpdatesSessionsAndLocalStateIgnoringSyncLocators() throws {
        try writer.write { db in
            try insertSession(db, id: "local", source: "codex", filePath: "", sourceLocator: "/tmp/local.jsonl")
            try insertSession(db, id: "sync", source: "codex", filePath: "", sourceLocator: "sync://peer/session")
            try db.execute(sql: "INSERT INTO session_local_state(session_id, local_readable_path) VALUES ('local', NULL), ('sync', NULL)")

            let changed = try StartupBackfills.backfillFilePaths(db)

            XCTAssertEqual(changed, 2)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT file_path FROM sessions WHERE id = 'local'"), "/tmp/local.jsonl")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT local_readable_path FROM session_local_state WHERE session_id = 'local'"), "/tmp/local.jsonl")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT file_path FROM sessions WHERE id = 'sync'"), "")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT local_readable_path FROM session_local_state WHERE session_id = 'sync'"))
        }
    }

    func testBackfillScoresMatchesNodeQualityScoringForEligibleSessions() throws {
        struct ScoreCase {
            let id: String
            let userCount: Int
            let assistantCount: Int
            let toolCount: Int
            let systemCount: Int
            let durationMinutes: Int
            let project: String?
        }

        let cases = [
            ScoreCase(
                id: "balanced-tool-session",
                userCount: 3,
                assistantCount: 3,
                toolCount: 2,
                systemCount: 1,
                durationMinutes: 10,
                project: "engram"
            ),
            ScoreCase(
                id: "short-chat-no-tools",
                userCount: 1,
                assistantCount: 1,
                toolCount: 0,
                systemCount: 0,
                durationMinutes: 2,
                project: nil
            ),
            ScoreCase(
                id: "long-tool-heavy-session",
                userCount: 8,
                assistantCount: 6,
                toolCount: 12,
                systemCount: 2,
                durationMinutes: 240,
                project: "infra"
            )
        ]

        try writer.write { db in
            for scoreCase in cases {
                try insertSession(
                    db,
                    id: scoreCase.id,
                    source: "codex",
                    startTime: "2026-04-23T10:00:00.000Z",
                    endTime: endTime(minutesAfterStart: scoreCase.durationMinutes),
                    project: scoreCase.project,
                    tier: "normal",
                    userMessageCount: scoreCase.userCount,
                    assistantMessageCount: scoreCase.assistantCount,
                    toolMessageCount: scoreCase.toolCount,
                    systemMessageCount: scoreCase.systemCount,
                    qualityScore: 0
                )
            }
            try insertSession(
                db,
                id: "skip-tier",
                source: "codex",
                tier: "skip",
                userMessageCount: 3,
                assistantMessageCount: 3,
                qualityScore: 0
            )

            let changed = try StartupBackfills.backfillScores(db)

            XCTAssertEqual(changed, cases.count)
            for scoreCase in cases {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT quality_score FROM sessions WHERE id = ?", arguments: [scoreCase.id]),
                    expectedQualityScore(
                        userCount: scoreCase.userCount,
                        assistantCount: scoreCase.assistantCount,
                        toolCount: scoreCase.toolCount,
                        systemCount: scoreCase.systemCount,
                        durationMinutes: Double(scoreCase.durationMinutes),
                        hasProject: scoreCase.project != nil
                    ),
                    scoreCase.id
                )
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT quality_score FROM sessions WHERE id = 'skip-tier'"), 0)
        }
    }

    func testDeduplicateFilePathsKeepsLatestRowid() throws {
        try writer.write { db in
            try insertSession(db, id: "old", source: "codex", filePath: "/tmp/dup.jsonl")
            try insertSession(db, id: "new", source: "codex", filePath: "/tmp/dup.jsonl")

            let removed = try StartupBackfills.deduplicateFilePaths(db)

            XCTAssertEqual(removed, 1)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT id FROM sessions WHERE id = 'old'"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT id FROM sessions WHERE file_path = '/tmp/dup.jsonl'"), "new")
        }
    }

    func testDeduplicateFilePathsRemovesOrphanedFtsRows() throws {
        try writer.write { db in
            try insertSession(db, id: "old", source: "codex", filePath: "/tmp/dup.jsonl")
            try insertSession(db, id: "new", source: "codex", filePath: "/tmp/dup.jsonl")
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('old', 'stale'), ('new', 'kept')")

            let removed = try StartupBackfills.deduplicateFilePaths(db)

            XCTAssertEqual(removed, 1)
            // The duplicate session row is gone AND its dangling FTS row was reconciled,
            // so search can no longer surface a session that no longer exists.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'old'"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'new'"), 1)
        }
    }

    func testDeduplicateFilePathsPurgesDeletedSessionArtifactTables_repro() throws {
        try writer.write { db in
            let leaked = "purge-leak-deduplicate"
            let kept = "purge-keep-deduplicate"
            try insertSession(db, id: "old", source: "codex", filePath: "/tmp/dup.jsonl")
            try insertSession(db, id: "new", source: "codex", filePath: "/tmp/dup.jsonl")
            try createRecoverableArtifactTables(db)
            try insertRecoverableArtifacts(db, sessionId: "old", content: leaked)
            try insertRecoverableArtifacts(db, sessionId: "new", content: kept)

            // PR #141 regression: deleting a duplicate session must remove every
            // recoverable content artifact keyed by the deleted session id.
            let removed = try StartupBackfills.deduplicateFilePaths(db)

            XCTAssertEqual(removed, 1)
            try assertRecoverableArtifactContent(db, content: leaked, expectedCount: 0)
            try assertRecoverableArtifactContent(db, content: kept, expectedCount: 4)
        }
    }

    func testDeduplicateFilePathsReparentsChildrenBeforeDeletingDuplicateParent() throws {
        try writer.write { db in
            try insertSession(db, id: "old-parent", source: "codex", filePath: "/tmp/parent.jsonl")
            try insertSession(db, id: "new-parent", source: "codex", filePath: "/tmp/parent.jsonl")
            try insertSession(db, id: "confirmed-child", source: "codex", filePath: "/tmp/confirmed-child.jsonl")
            try insertSession(db, id: "suggested-child", source: "codex", filePath: "/tmp/suggested-child.jsonl")
            try db.execute(
                sql: """
                UPDATE sessions SET parent_session_id = 'old-parent', link_source = 'path' WHERE id = 'confirmed-child';
                UPDATE sessions SET suggested_parent_id = 'old-parent' WHERE id = 'suggested-child';
                """
            )

            let removed = try StartupBackfills.deduplicateFilePaths(db)

            XCTAssertEqual(removed, 1)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT id FROM sessions WHERE id = 'old-parent'"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'confirmed-child'"),
                "new-parent"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'suggested-child'"),
                "new-parent"
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = 'confirmed-child'"), "path")
        }
    }

    func testSessionDeleteTriggerNullifiesChildParentSessionId() throws {
        try writer.write { db in
            try insertSession(db, id: "parent", source: "codex", filePath: "/tmp/parent.jsonl")
            try insertSession(db, id: "child", source: "codex", filePath: "/tmp/child.jsonl", tier: "normal")
            try db.execute(
                sql: "UPDATE sessions SET parent_session_id = 'parent', link_source = 'manual' WHERE id = 'child'"
            )

            try db.execute(sql: "DELETE FROM sessions WHERE id = 'parent'")

            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'child'"))
        }
    }

    func testDeletingSessionRetainsInsightSourceSessionReferenceByDesign() throws {
        try writer.write { db in
            try insertSession(db, id: "source-session", source: "codex", filePath: "/tmp/source.jsonl")
            try db.execute(
                sql: """
                INSERT INTO insights(id, content, source_session_id, importance)
                VALUES ('insight-source', 'retained provenance insight', 'source-session', 5)
                """
            )

            try db.execute(sql: "DELETE FROM sessions WHERE id = 'source-session'")

            // source_session_id is retained provenance, not a cascading foreign key.
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT source_session_id FROM insights WHERE id = 'insight-source'"),
                "source-session"
            )
        }
    }

    func testCleanupStaleMigrationsFailsOnlyOldNonTerminalRows() throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO migration_log(id, old_path, new_path, old_basename, new_basename, state, started_at)
                VALUES
                  ('stale', '/old', '/new', 'old', 'new', 'fs_pending', datetime('now', '-25 hours')),
                  ('fresh', '/old2', '/new2', 'old2', 'new2', 'fs_done', datetime('now', '-1 hours')),
                  ('done', '/old3', '/new3', 'old3', 'new3', 'committed', datetime('now', '-25 hours'))
                """
            )

            let cleaned = try StartupBackfills.cleanupStaleMigrations(db)

            XCTAssertEqual(cleaned, 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_log WHERE id = 'stale'"), "failed")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_log WHERE id = 'fresh'"), "fs_done")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM migration_log WHERE id = 'done'"), "committed")
        }
    }

    func testOrphanScanAppliesTransitionsWithoutHoldingWriteGateAcrossProbe() async throws {
        // Recovered: previously flagged but the file is accessible again.
        // Newly flagged: unflagged + inaccessible.
        // Confirmed: long-suspect (past grace) + still inaccessible.
        // Skipped: sync locator (never probed).
        try writer.write { db in
            try insertSession(db, id: "recover", source: "codex", filePath: "/files/recover.jsonl")
            try db.execute(sql: "UPDATE sessions SET orphan_status = 'suspect', orphan_since = datetime('now') WHERE id = 'recover'")
            try insertSession(db, id: "flag", source: "codex", filePath: "/files/flag.jsonl")
            try insertSession(db, id: "confirm", source: "codex", filePath: "/files/confirm.jsonl")
            try db.execute(sql: "UPDATE sessions SET orphan_status = 'suspect', orphan_since = datetime('now', '-40 days') WHERE id = 'confirm'")
            try insertSession(db, id: "synced", source: "codex", filePath: "", sourceLocator: "sync://peer/x")
        }

        let adapter = FakeAccessibilityAdapter(
            accessibleLocators: ["/files/recover.jsonl"]
        )
        let scanner = WriterStartupOrphanScanning(writer: writer)

        let result = try await scanner.detectOrphans(adapters: [adapter])

        XCTAssertEqual(result.recovered, 1)
        XCTAssertEqual(result.newlyFlagged, 1)
        XCTAssertEqual(result.confirmed, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.scanned, 4)

        try writer.read { db in
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT orphan_status FROM sessions WHERE id = 'recover'"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT orphan_status FROM sessions WHERE id = 'flag'"), "suspect")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT orphan_status FROM sessions WHERE id = 'confirm'"), "confirmed")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT orphan_status FROM sessions WHERE id = 'synced'"))
        }
    }

    func testEnqueueStaleFtsJobsAddsPendingJobForCurrentSnapshotHash() throws {
        try writer.write { db in
            try insertSession(db, id: "stale", source: "codex", tier: "normal")
            try insertSession(db, id: "fresh", source: "codex", tier: "normal")
            try insertSession(db, id: "skip", source: "codex", tier: "skip")
            try db.execute(sql: "UPDATE sessions SET sync_version = 1, snapshot_hash = 'current' WHERE id IN ('stale', 'fresh', 'skip')")
            try db.execute(
                sql: """
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
                VALUES
                  ('stale:1:old:fts', 'stale', 'fts', 1, 'completed'),
                  ('fresh:1:current:fts', 'fresh', 'fts', 1, 'completed'),
                  ('skip:1:old:fts', 'skip', 'fts', 1, 'completed')
                """
            )

            let enqueued = try StartupBackfills.enqueueStaleFtsJobs(db)

            XCTAssertEqual(enqueued, 1)
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT id FROM session_index_jobs WHERE status = 'pending' ORDER BY id"
                ),
                ["stale:1:current:fts"]
            )
        }
    }

    func testOptimizeFtsGatesOnContentSignature() throws {
        try writer.write { db in
            try insertSession(db, id: "s1", source: "codex", tier: "normal")
            try db.execute(sql: "UPDATE sessions SET sync_version = 1, indexed_at = '2026-05-01T00:00:00Z' WHERE id = 's1'")

            XCTAssertTrue(try StartupBackfills.optimizeFts(db), "first optimize runs and stores the signature")
            XCTAssertFalse(try StartupBackfills.optimizeFts(db), "unchanged FTS content must skip optimize")

            // New non-skip content changes the signature and re-runs optimize.
            try insertSession(db, id: "s2", source: "codex", tier: "normal")
            XCTAssertTrue(try StartupBackfills.optimizeFts(db), "changed content must run optimize")
            XCTAssertFalse(try StartupBackfills.optimizeFts(db))
        }
    }

    func testOptimizeFtsReRunsWhenStoredSignatureLacksRebuildVersion() throws {
        try writer.write { db in
            try insertSession(db, id: "s1", source: "codex", tier: "normal")
            try db.execute(sql: "UPDATE sessions SET sync_version = 1, indexed_at = '2026-05-01T00:00:00Z' WHERE id = 's1'")
            try db.execute(
                sql: """
                INSERT INTO metadata(key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [StartupBackfills.ftsOptimizeSignatureKey, "1:1:2026-05-01T00:00:00Z:0:"]
            )

            XCTAssertTrue(try StartupBackfills.optimizeFts(db))
            XCTAssertFalse(try StartupBackfills.optimizeFts(db))
        }
    }

    func testOptimizeFtsIfDueHonorsMinimumIntervalCadence() throws {
        // Wave-6 task 6: periodic path must not re-enter optimize every 5-min tick.
        let t0 = ISO8601DateFormatter().date(from: "2026-07-09T00:00:00Z")!
        let t1h = t0.addingTimeInterval(60 * 60)
        let t25h = t0.addingTimeInterval(25 * 60 * 60)
        let minInterval: TimeInterval = 24 * 60 * 60

        try writer.write { db in
            try insertSession(db, id: "s1", source: "codex", tier: "normal")
            try db.execute(sql: "UPDATE sessions SET sync_version = 1, indexed_at = '2026-05-01T00:00:00Z' WHERE id = 's1'")

            XCTAssertTrue(
                try StartupBackfills.optimizeFtsIfDue(db, now: t0, minInterval: minInterval),
                "first due attempt must run optimize when content is new"
            )
            let signatureAfterFirst = try String.fetchOne(
                db,
                sql: "SELECT value FROM metadata WHERE key = ?",
                arguments: [StartupBackfills.ftsOptimizeSignatureKey]
            )
            XCTAssertNotNil(signatureAfterFirst)

            // Content change within the interval must still be interval-gated.
            try insertSession(db, id: "s2", source: "codex", tier: "normal")
            XCTAssertFalse(
                try StartupBackfills.optimizeFtsIfDue(db, now: t1h, minInterval: minInterval),
                "within min interval must not re-attempt even when content changed"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT value FROM metadata WHERE key = ?",
                    arguments: [StartupBackfills.ftsOptimizeSignatureKey]
                ),
                signatureAfterFirst,
                "interval skip must not rewrite the stored optimize signature"
            )

            XCTAssertTrue(
                try StartupBackfills.optimizeFtsIfDue(db, now: t25h, minInterval: minInterval),
                "after min interval elapses, changed content must optimize again"
            )
        }
    }

    func testOptimizeFtsIfDueStillHonorsContentSignatureWhenDue() throws {
        let t0 = ISO8601DateFormatter().date(from: "2026-07-09T00:00:00Z")!
        let t25h = t0.addingTimeInterval(25 * 60 * 60)
        let minInterval: TimeInterval = 24 * 60 * 60

        try writer.write { db in
            try insertSession(db, id: "s1", source: "codex", tier: "normal")
            try db.execute(sql: "UPDATE sessions SET sync_version = 1, indexed_at = '2026-05-01T00:00:00Z' WHERE id = 's1'")

            XCTAssertTrue(try StartupBackfills.optimizeFtsIfDue(db, now: t0, minInterval: minInterval))
            // Interval elapsed, but content signature unchanged → skip rewrite.
            XCTAssertFalse(
                try StartupBackfills.optimizeFtsIfDue(db, now: t25h, minInterval: minInterval),
                "due interval must still defer to the content-signature gate"
            )
        }
    }

    func testReconcileSkipTierDeletesStaleArtifactsWithoutTouchingTierOrNonSkip() throws {
        try writer.write { db in
            try insertSession(db, id: "skip-1", source: "codex", tier: "skip")
            try insertSession(db, id: "keep-1", source: "codex", tier: "normal")
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES ('skip-1', 'stale'), ('keep-1', 'kept')")
            try db.execute(
                sql: """
                INSERT INTO fts_map(session_id, msg_seq, fts_rowid, content_hash) VALUES
                  ('skip-1', 0, 1, 'stalehash'),
                  ('keep-1', 0, 2, 'keephash')
                """
            )
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS session_embeddings(session_id TEXT PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO session_embeddings(session_id) VALUES ('skip-1'), ('keep-1')")
            // The skip session still owns a completed fts job — the cheap signal
            // that stale artifacts remain.
            try db.execute(
                sql: """
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status) VALUES
                  ('skip-1:1:h:fts', 'skip-1', 'fts', 1, 'completed'),
                  ('keep-1:1:h:fts', 'keep-1', 'fts', 1, 'completed')
                """
            )

            let removed = try StartupBackfills.reconcileSkipTierIndexArtifacts(db)

            XCTAssertEqual(removed, 3)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'skip-1'"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'keep-1'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fts_map WHERE session_id = 'skip-1'"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fts_map WHERE session_id = 'keep-1'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_embeddings WHERE session_id = 'skip-1'"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_embeddings WHERE session_id = 'keep-1'"), 1)
            // Tier is never modified (subagent/skip invariant preserved).
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'skip-1'"), "skip")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'keep-1'"), "normal")
            // The skip session's obsolete job is cleared; the non-skip one remains.
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT id FROM session_index_jobs WHERE session_id = 'skip-1'"))
            XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT id FROM session_index_jobs WHERE session_id = 'keep-1'"))
            // Idempotent: nothing qualifies now, so a re-run is a no-op.
            XCTAssertEqual(try StartupBackfills.reconcileSkipTierIndexArtifacts(db), 0)
        }
    }

    func testReconcileSkipTierPurgesLegacyMessageArtifacts_repro() throws {
        try writer.write { db in
            let leaked = "purge-leak-reconcile-skip-tier"
            let kept = "purge-keep-reconcile-skip-tier"
            try insertSession(db, id: "skip-legacy", source: "codex", tier: "skip")
            try insertSession(db, id: "keep-legacy", source: "codex", tier: "normal")
            try createRecoverableArtifactTables(db)
            try insertRecoverableArtifacts(db, sessionId: "skip-legacy", content: leaked)
            try insertRecoverableArtifacts(db, sessionId: "keep-legacy", content: kept)
            try db.execute(
                sql: """
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
                VALUES ('skip-legacy:1:h:fts', 'skip-legacy', 'fts', 1, 'completed')
                """
            )

            // PR #141 regression: startup reconciliation must purge legacy cached
            // message rows for skip-tier sessions alongside FTS and embeddings.
            let removed = try StartupBackfills.reconcileSkipTierIndexArtifacts(db)

            XCTAssertEqual(removed, 4)
            try assertRecoverableArtifactContent(db, content: leaked, expectedCount: 0)
            try assertRecoverableArtifactContent(db, content: kept, expectedCount: 4)
        }
    }

    func testReconcileSkipTierPurgesJoblessLegacyArtifacts_repro() throws {
        try writer.write { db in
            let leaked = "purge-leak-jobless-skip-tier"
            let kept = "purge-keep-jobless-skip-tier"
            try insertSession(db, id: "skip-jobless", source: "codex", tier: "skip")
            try insertSession(db, id: "keep-jobless", source: "codex", tier: "normal")
            try createRecoverableArtifactTables(db)
            try insertRecoverableArtifacts(db, sessionId: "skip-jobless", content: leaked)
            try insertRecoverableArtifacts(db, sessionId: "keep-jobless", content: kept)

            // PR #141 regression: cheap companion artifacts must trigger skip
            // reconciliation even when obsolete session_index_jobs rows are absent.
            let removed = try StartupBackfills.reconcileSkipTierIndexArtifacts(db)

            XCTAssertEqual(removed, 4)
            try assertRecoverableArtifactContent(db, content: leaked, expectedCount: 0)
            try assertRecoverableArtifactContent(db, content: kept, expectedCount: 4)
        }
    }

    func testReconcileSkipTierPurgesJoblessFtsOnlyArtifacts_repro() throws {
        try writer.write { db in
            let leaked = "purge-leak-jobless-fts-only"
            let kept = "purge-keep-jobless-fts-only"
            try insertSession(db, id: "skip-fts-only", source: "codex", tier: "skip")
            try insertSession(db, id: "keep-fts-only", source: "codex", tier: "normal")
            try db.execute(
                sql: """
                INSERT INTO sessions_fts(session_id, content)
                VALUES
                  ('skip-fts-only', ?),
                  ('keep-fts-only', ?)
                """,
                arguments: [leaked, kept]
            )

            // PR #141 regression: the one-time migration sweep must catch stale
            // skip-tier FTS rows even when no job or companion artifact remains.
            let removed = try StartupBackfills.reconcileSkipTierIndexArtifacts(db)

            XCTAssertEqual(removed, 1)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE content = ?", arguments: [leaked]),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE content = ?", arguments: [kept]),
                1
            )
            XCTAssertEqual(try StartupBackfills.reconcileSkipTierIndexArtifacts(db), 0)
        }
    }

    func testReconcileSkipTierDeleteCountIncludesEmbeddings_repro() throws {
        try writer.write { db in
            try insertSession(db, id: "skip-count", source: "codex", tier: "skip")
            try insertSession(db, id: "keep-count", source: "codex", tier: "normal")
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS session_embeddings(
                  session_id TEXT PRIMARY KEY,
                  content TEXT
                )
                """
            )
            try db.execute(
                sql: """
                INSERT INTO sessions_fts(session_id, content)
                VALUES
                  ('skip-count', 'skip count fts'),
                  ('keep-count', 'keep count fts')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO session_embeddings(session_id, content)
                VALUES
                  ('skip-count', 'skip count embedding'),
                  ('keep-count', 'keep count embedding')
                """
            )

            // PR #142 regression: telemetry must include the embedding row
            // deleted for skip-tier sessions, not just the FTS row count.
            let removed = try StartupBackfills.reconcileSkipTierIndexArtifacts(db)

            XCTAssertEqual(removed, 2)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'skip-count'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_embeddings WHERE session_id = 'skip-count'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 'keep-count'"),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_embeddings WHERE session_id = 'keep-count'"),
                1
            )
        }
    }

    func testPruneIndexJobsKeepsInFlightAndLatestTerminalPerKind() throws {
        try writer.write { db in
            try insertSession(db, id: "hot", source: "codex", tier: "normal")
            try db.execute(
                sql: """
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status) VALUES
                  ('hot:1:a:fts', 'hot', 'fts', 1, 'completed'),
                  ('hot:2:b:fts', 'hot', 'fts', 2, 'completed'),
                  ('hot:3:c:fts', 'hot', 'fts', 3, 'not_applicable'),
                  ('hot:4:d:fts', 'hot', 'fts', 4, 'pending'),
                  ('hot:1:a:embedding', 'hot', 'embedding', 1, 'completed'),
                  ('hot:2:b:embedding', 'hot', 'embedding', 2, 'failed_retryable')
                """
            )

            let removed = try StartupBackfills.pruneIndexJobs(db)

            // Only the two older terminal fts rows are pruned; the latest terminal
            // per kind and every in-flight row survive.
            XCTAssertEqual(removed, 2)
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT id FROM session_index_jobs ORDER BY rowid"),
                ["hot:3:c:fts", "hot:4:d:fts", "hot:1:a:embedding", "hot:2:b:embedding"]
            )
        }
    }

    func testOrphanScanSkipsWithinMinimumInterval() async throws {
        try writer.write { db in
            try insertSession(db, id: "missing", source: "codex", filePath: "/files/missing.jsonl")
            try db.execute(sql: "INSERT INTO metadata(key, value) VALUES ('last_orphan_scan', datetime('now'))")
        }
        let scanner = WriterStartupOrphanScanning(writer: writer)

        let result = try await scanner.detectOrphans(adapters: [FakeAccessibilityAdapter(accessibleLocators: [])])

        XCTAssertEqual(result.scanned, 0, "a scan within 24h must be skipped")
        try writer.read { db in
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT orphan_status FROM sessions WHERE id = 'missing'"),
                "the inaccessible session must not be flagged when the scan is skipped"
            )
        }
    }

    func testOrphanScanRunsAndStampsTimestampWhenLastScanIsStale() async throws {
        try writer.write { db in
            try insertSession(db, id: "missing", source: "codex", filePath: "/files/missing.jsonl")
            try db.execute(sql: "INSERT INTO metadata(key, value) VALUES ('last_orphan_scan', datetime('now', '-2 days'))")
        }
        let scanner = WriterStartupOrphanScanning(writer: writer)

        let result = try await scanner.detectOrphans(adapters: [FakeAccessibilityAdapter(accessibleLocators: [])])

        XCTAssertEqual(result.scanned, 1)
        XCTAssertEqual(result.newlyFlagged, 1)
        try writer.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT orphan_status FROM sessions WHERE id = 'missing'"), "suspect")
            XCTAssertNotNil(
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'last_orphan_scan'"),
                "a completed scan must refresh the gating timestamp"
            )
        }
    }

    private func insertSession(
        _ db: Database,
        id: String,
        source: String,
        startTime: String = "2026-04-23T10:00:00.000Z",
        endTime: String? = "2026-04-23T11:00:00.000Z",
        cwd: String = "",
        project: String? = nil,
        summary: String? = nil,
        filePath: String = "/tmp/session.jsonl",
        sourceLocator: String? = nil,
        agentRole: String? = nil,
        tier: String? = nil,
        linkSource: String? = nil,
        linkCheckedAt: String? = nil,
        suggestionStatus: String? = nil,
        suggestionCandidates: String? = nil,
        model: String? = nil,
        userMessageCount: Int = 0,
        assistantMessageCount: Int = 0,
        toolMessageCount: Int = 0,
        systemMessageCount: Int = 0,
        qualityScore: Int? = nil
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO sessions(
              id, source, start_time, end_time, cwd, project, summary, file_path,
              source_locator, agent_role, tier, link_source, link_checked_at,
              suggestion_status, suggestion_candidates,
              model, user_message_count, assistant_message_count, tool_message_count, system_message_count,
              quality_score
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                id, source, startTime, endTime, cwd, project, summary, filePath,
                sourceLocator, agentRole, tier, linkSource, linkCheckedAt,
                suggestionStatus, suggestionCandidates, model,
                userMessageCount, assistantMessageCount, toolMessageCount, systemMessageCount,
                qualityScore
            ]
        )
    }

    private func createRecoverableArtifactTables(_ db: Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE IF NOT EXISTS messages(
              session_id TEXT NOT NULL,
              msg_seq INTEGER NOT NULL,
              content TEXT NOT NULL,
              PRIMARY KEY(session_id, msg_seq)
            );
            """
        )
        try db.execute(
            sql: """
            CREATE TABLE IF NOT EXISTS session_embeddings(
              session_id TEXT PRIMARY KEY,
              content TEXT
            );
            """
        )
    }

    private func insertRecoverableArtifacts(_ db: Database, sessionId: String, content: String) throws {
        try db.execute(
            sql: "INSERT INTO messages(session_id, msg_seq, content) VALUES (?, 0, ?)",
            arguments: [sessionId, content]
        )
        try db.execute(
            sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
            arguments: [sessionId, content]
        )
        let rowID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO fts_map(session_id, msg_seq, fts_rowid, content_hash) VALUES (?, 0, ?, ?)",
            arguments: [sessionId, rowID, content]
        )
        try db.execute(
            sql: "INSERT INTO session_embeddings(session_id, content) VALUES (?, ?)",
            arguments: [sessionId, content]
        )
    }

    private func assertRecoverableArtifactContent(_ db: Database, content: String, expectedCount: Int) throws {
        let pattern = "%\(content)%"
        let messages = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM messages WHERE content LIKE ?",
            arguments: [pattern]
        ) ?? 0
        let fts = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sessions_fts WHERE content LIKE ?",
            arguments: [pattern]
        ) ?? 0
        let ftsMap = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM fts_map WHERE content_hash LIKE ?",
            arguments: [pattern]
        ) ?? 0
        let embeddings = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM session_embeddings WHERE content LIKE ?",
            arguments: [pattern]
        ) ?? 0
        XCTAssertEqual(messages + fts + ftsMap + embeddings, expectedCount)
    }

    private func writeCodexRollout(
        id: String,
        turnContextModel: String? = nil,
        responseItemModel: String? = nil,
        sessionMetaModel: String? = nil,
        modelProvider: String? = nil
    ) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-model-label-\(UUID().uuidString).jsonl")
        var metaPayload: [String: String] = [
            "id": id,
            "timestamp": "2026-07-01T10:00:00.000Z",
            "cwd": "/tmp/\(id)"
        ]
        if let sessionMetaModel {
            metaPayload["model"] = sessionMetaModel
        }
        if let modelProvider {
            metaPayload["model_provider"] = modelProvider
        }

        var lines: [[String: Any]] = [
            [
                "timestamp": "2026-07-01T10:00:00.000Z",
                "type": "session_meta",
                "payload": metaPayload
            ]
        ]
        if let turnContextModel {
            lines.append(
                [
                    "timestamp": "2026-07-01T10:00:00.100Z",
                    "type": "turn_context",
                    "payload": ["model": turnContextModel]
                ]
            )
        }
        var responsePayload: [String: Any] = [
            "type": "message",
            "role": "assistant",
            "content": [["type": "output_text", "text": "ok"]]
        ]
        if let responseItemModel {
            responsePayload["model"] = responseItemModel
        }
        lines.append(
            [
                "timestamp": "2026-07-01T10:00:01.000Z",
                "type": "response_item",
                "payload": responsePayload
            ]
        )

        let contents = try lines
            .map { object -> String in
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                return String(decoding: data, as: UTF8.self)
            }
            .joined(separator: "\n")
            .appending("\n")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func endTime(minutesAfterStart: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = formatter.date(from: "2026-04-23T10:00:00.000Z")!
        let end = start.addingTimeInterval(TimeInterval(minutesAfterStart * 60))
        return formatter.string(from: end)
    }

    private func expectedQualityScore(
        userCount: Int,
        assistantCount: Int,
        toolCount: Int,
        systemCount: Int,
        durationMinutes: Double,
        hasProject: Bool
    ) -> Int {
        let totalMessages = userCount + assistantCount + toolCount + systemCount
        var turnScore = 0.0
        if userCount > 0, assistantCount > 0, totalMessages > 0 {
            turnScore = min(30, (Double(min(userCount, assistantCount)) / Double(totalMessages)) * 30)
        }

        var toolScore = 0.0
        if assistantCount > 0 {
            toolScore = min(25, (Double(toolCount) / Double(assistantCount)) * 50)
        }

        let densityScore: Double
        if durationMinutes < 1 {
            densityScore = 0
        } else if durationMinutes <= 5 {
            densityScore = (durationMinutes / 5) * 20
        } else if durationMinutes <= 60 {
            densityScore = 20
        } else if durationMinutes <= 180 {
            densityScore = 20 - ((durationMinutes - 60) / 120) * 10
        } else {
            densityScore = 10
        }

        let projectScore = hasProject ? 15.0 : 0.0
        let volumeScore = min(10, Double(userCount + assistantCount + toolCount) / 5)
        return max(0, min(100, Int((turnScore + toolScore + densityScore + projectScore + volumeScore).rounded())))
    }
}

private struct StoredAmbiguousCandidate: Decodable, Equatable {
    var id: String
    var score: Double
}

private enum TestError: Error, CustomStringConvertible {
    case expected

    var description: String { "expected" }
}

/// Minimal adapter whose `isAccessible` answers from a fixed allowlist; the scan
/// only ever calls `isAccessible`, so the other members are unreachable stubs.
private final class FakeAccessibilityAdapter: SessionAdapter {
    let source: SourceName = .codex
    private let accessibleLocators: Set<String>

    init(accessibleLocators: Set<String>) {
        self.accessibleLocators = accessibleLocators
    }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { [] }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .failure(.fileMissing)
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func isAccessible(locator: String) async -> Bool {
        accessibleLocators.contains(locator)
    }
}

private final class RecordingStartupLogger: StartupBackfillLogging {
    var warnings: [String] = []

    func warn(_ message: String, error: Error) {
        warnings.append("\(message): \(error)")
    }
}

private final class RecordingStartupUsageCollector: StartupUsageCollecting {
    var didStart = false

    func start() {
        didStart = true
    }
}

private final class RecordingStartupIndexer: StartupIndexing {
    var usesInlineCountAndCostBackfills = false
    var indexed: Int
    var countBackfilled: Int
    var costBackfilled: Int
    var countBackfillError: Error?
    var costBackfillError: Error?

    init(indexed: Int, countBackfilled: Int = 0, costBackfilled: Int = 0) {
        self.indexed = indexed
        self.countBackfilled = countBackfilled
        self.costBackfilled = costBackfilled
    }

    func indexAll() async throws -> Int {
        return indexed
    }

    func backfillCounts() async throws -> Int {
        if let countBackfillError { throw countBackfillError }
        return countBackfilled
    }

    func backfillCosts() async throws -> Int {
        if let costBackfillError { throw costBackfillError }
        return costBackfilled
    }
}

private final class RecordingStartupIndexJobRunner: StartupIndexJobRunning {
    var completed: Int
    var notApplicable: Int
    var promoted: Int
    var recoverError: Error?
    var promoteError: Error?

    init(completed: Int = 23, notApplicable: Int = 24, promoted: Int = 25) {
        self.completed = completed
        self.notApplicable = notApplicable
        self.promoted = promoted
    }

    func runRecoverableJobs() async throws -> StartupIndexJobRecoveryResult {
        if let recoverError { throw recoverError }
        return StartupIndexJobRecoveryResult(completed: completed, notApplicable: notApplicable)
    }

    func backfillInsightEmbeddings() async throws -> Int {
        if let promoteError { throw promoteError }
        return promoted
    }
}

private final class RecordingStartupOrphanScanner: StartupOrphanScanning {
    var scanned: Int
    var newlyFlagged: Int
    var confirmed: Int
    var recovered: Int
    var skipped: Int
    var error: Error?

    init(scanned: Int = 18, newlyFlagged: Int = 19, confirmed: Int = 20, recovered: Int = 21, skipped: Int = 22) {
        self.scanned = scanned
        self.newlyFlagged = newlyFlagged
        self.confirmed = confirmed
        self.recovered = recovered
        self.skipped = skipped
    }

    func detectOrphans(adapters: [any SessionAdapter]) async throws -> StartupOrphanScanResult {
        if let error { throw error }
        return StartupOrphanScanResult(
            scanned: scanned,
            newlyFlagged: newlyFlagged,
            confirmed: confirmed,
            recovered: recovered,
            skipped: skipped
        )
    }
}

private final class RecordingStartupDatabase: StartupBackfillDatabase {
    var callOrder: [String] = []
    var backfillScoresError: Error?
    var filePathBackfillError: Error?

    func countSessions() throws -> Int {
        callOrder.append("countSessions")
        return 16
    }

    func countTodayParentSessions() throws -> Int {
        callOrder.append("countTodayParentSessions")
        return 17
    }

    func backfillScores() throws -> Int {
        callOrder.append("backfillScores")
        if let backfillScoresError { throw backfillScoresError }
        return 4
    }

    func deduplicateFilePaths() throws -> Int {
        callOrder.append("deduplicateFilePaths")
        return 5
    }

    func optimizeFts() throws {
        callOrder.append("optimizeFts")
    }

    func vacuumIfNeeded(_ fragmentationPercent: Int) throws -> Bool {
        callOrder.append("vacuumIfNeeded")
        XCTAssertEqual(fragmentationPercent, 15)
        return true
    }

    func reconcileInsights() throws -> StartupInsightReconcileResult {
        callOrder.append("reconcileInsights")
        return StartupInsightReconcileResult(resetEmbedding: 6, orphanedVector: 7)
    }

    func reconcileGroupedSourceDirs() throws -> GroupedDirReconcileResult {
        callOrder.append("reconcileGroupedSourceDirs")
        return GroupedDirReconcileResult(
            scannedDirs: 30,
            plannedRenames: 31,
            appliedRenames: 32,
            collisions: 33,
            ambiguous: 34,
            issues: 35
        )
    }

    func backfillFilePaths() throws -> Int {
        callOrder.append("backfillFilePaths")
        if let filePathBackfillError { throw filePathBackfillError }
        return 8
    }

    func downgradeSubagentTiers() throws -> Int {
        callOrder.append("downgradeSubagentTiers")
        return 9
    }

    func backfillParentLinks() throws -> StartupBackfills.ParentLinkResult {
        callOrder.append("backfillParentLinks")
        return StartupBackfills.ParentLinkResult(linked: 10)
    }

    func resetStaleDetections() throws -> Int {
        callOrder.append("resetStaleDetections")
        return 11
    }

    func backfillCodexOriginator() throws -> Int {
        callOrder.append("backfillCodexOriginator")
        return 12
    }

    func backfillCodexModelLabels() throws -> Int {
        callOrder.append("backfillCodexModelLabels")
        return 30
    }

    func backfillPolycliProviderParents() throws -> StartupBackfills.ProviderParentResult {
        callOrder.append("backfillPolycliProviderParents")
        return StartupBackfills.ProviderParentResult(checked: 26, classified: 27, linked: 28, suggested: 29)
    }

    func backfillSuggestedParents() throws -> StartupBackfills.SuggestedParentResult {
        callOrder.append("backfillSuggestedParents")
        return StartupBackfills.SuggestedParentResult(checked: 13, suggested: 14)
    }

    func enqueueStaleFtsJobs() throws -> Int {
        callOrder.append("enqueueStaleFtsJobs")
        return 29
    }

    func reconcileSkipTierIndexArtifacts() throws -> Int {
        callOrder.append("reconcileSkipTierIndexArtifacts")
        return 0
    }

    func pruneIndexJobs() throws -> Int {
        callOrder.append("pruneIndexJobs")
        return 0
    }

    func cleanupStaleMigrations() throws -> Int {
        callOrder.append("cleanupStaleMigrations")
        return 15
    }
}
