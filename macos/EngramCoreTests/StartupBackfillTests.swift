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

    func testDowngradeSubagentTiersRemovesShadowFTSRows_repro() throws {
        try writer.write { db in
            try insertSession(db, id: "subagent-shadow", source: "codex", agentRole: "subagent", tier: "lite")
            try insertSession(db, id: "normal-shadow", source: "codex", tier: "normal")
            try db.execute(sql: "CREATE TABLE sessions_fts_rebuild(session_id TEXT NOT NULL, content TEXT NOT NULL)")
            try db.execute(
                sql: "INSERT INTO sessions_fts_rebuild(session_id, content) VALUES ('subagent-shadow', 'hidden'), ('normal-shadow', 'visible')"
            )

            XCTAssertEqual(try StartupBackfills.downgradeSubagentTiers(db), 1)
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT session_id FROM sessions_fts_rebuild ORDER BY session_id"),
                ["normal-shadow"]
            )
        }
    }

    func testDowngradeSubagentTiersPurgesFtsMapArtifacts_repro() throws {
        try writer.write { db in
            let leaked = "purge-leak-subagent-downgrade"
            let nullableLeaked = "purge-leak-null-subagent-downgrade"
            let kept = "purge-keep-subagent-downgrade"
            let nullableKept = "purge-keep-null-session-downgrade"
            try insertSession(db, id: "subagent-1", source: "codex", agentRole: "subagent", tier: "lite")
            try insertSession(db, id: "subagent-null", source: "codex", agentRole: "subagent")
            try insertSession(db, id: "normal-1", source: "codex", tier: "normal")
            try insertSession(db, id: "normal-null", source: "codex")
            try createRecoverableArtifactTables(db)
            try insertRecoverableArtifacts(db, sessionId: "subagent-1", content: leaked)
            try insertRecoverableArtifacts(db, sessionId: "subagent-null", content: nullableLeaked)
            try insertRecoverableArtifacts(db, sessionId: "normal-1", content: kept)
            try insertRecoverableArtifacts(db, sessionId: "normal-null", content: nullableKept)
            try insertSemanticChunk(db, sessionId: "subagent-1", text: leaked)
            try insertSemanticChunk(db, sessionId: "subagent-null", text: nullableLeaked)
            try insertSemanticChunk(db, sessionId: "normal-1", text: kept)
            try insertSemanticChunk(db, sessionId: "normal-null", text: nullableKept)

            // PR #141 and EMB-001 regressions: batch skip cleanup must purge
            // cached messages, FTS, and both legacy and current embedding artifacts.
            let changed = try StartupBackfills.downgradeSubagentTiers(db)

            XCTAssertEqual(changed, 2)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'subagent-null'"),
                "skip"
            )
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'normal-null'"))
            try assertRecoverableArtifactContent(db, content: leaked, expectedCount: 0)
            try assertRecoverableArtifactContent(db, content: nullableLeaked, expectedCount: 0)
            try assertRecoverableArtifactContent(db, content: kept, expectedCount: 4)
            try assertRecoverableArtifactContent(db, content: nullableKept, expectedCount: 4)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_chunks WHERE session_id = 'subagent-1'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_chunks WHERE session_id = 'subagent-null'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_chunks WHERE session_id = 'normal-1'"),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_chunks WHERE session_id = 'normal-null'"),
                1
            )
        }
    }

    func testBackfillParentLinksUsesPathAndPreservesManualLinks() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-parent-backfill-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = home.appendingPathComponent(".claude/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try writer.write { db in
            try insertSession(db, id: "parent-1", source: "claude-code", tier: "normal")
            try insertSession(
                db,
                id: "child-1",
                source: "claude-code",
                filePath: projectsRoot.appendingPathComponent("encoded/parent-1/subagents/worker.jsonl").path,
                agentRole: "subagent",
                tier: "skip",
                suggestionStatus: "ambiguous",
                suggestionCandidates: "[{\"id\":\"old\",\"score\":0.91}]"
            )
            try insertSession(
                db,
                id: "manual-child",
                source: "claude-code",
                filePath: projectsRoot.appendingPathComponent("encoded/parent-1/subagents/manual.jsonl").path,
                agentRole: "subagent",
                tier: "skip",
                linkSource: "manual"
            )

            let result = try StartupBackfills.backfillParentLinks(db, homeDirectory: home)
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

    func testQoderBackfillScansPastSidecarFirstLineAndNeverUsesEncodedProjectAsParent_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoder-backfill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appendingPathComponent(".qoder/projects", isDirectory: true)
        let childFile = projectsRoot.appendingPathComponent("encoded-project/subagents/agent.jsonl")
        try FileManager.default.createDirectory(
            at: childFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rows = [
            #"{"type":"file-history-snapshot","snapshot":""#
                + String(repeating: "x", count: 300 * 1_024)
                + #""}"#,
            #"{"type":"user","sessionId":"qoder-parent","message":{"role":"user","content":"work"}}"#,
        ]
        try rows.joined(separator: "\n").appending("\n")
            .write(to: childFile, atomically: true, encoding: .utf8)

        try writer.write { db in
            try insertSession(db, id: "qoder-parent", source: "qoder", filePath: projectsRoot.appendingPathComponent("encoded-project/qoder-parent.jsonl").path)
            try insertSession(
                db,
                id: "sub:qoder-parent:subagents/agent.jsonl",
                source: "qoder",
                filePath: childFile.path,
                agentRole: "subagent",
                tier: "skip"
            )

            XCTAssertEqual(
                try StartupBackfills.backfillParentLinks(db, homeDirectory: root).linked,
                1
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT parent_session_id FROM sessions WHERE id = 'sub:qoder-parent:subagents/agent.jsonl'"
                ),
                "qoder-parent"
            )
        }
    }

    func testParentBackfillDoesNotInventHostFromUnconfinedSubagentsName_repro() throws {
        let locator = "/tmp/home/.claude/projects/subagents/session.jsonl"
        try writer.write { db in
            try insertSession(db, id: "projects", source: "claude-code", tier: "normal")
            try insertSession(
                db,
                id: "unconfined-child",
                source: "claude-code",
                filePath: locator,
                agentRole: "subagent",
                tier: "skip"
            )

            XCTAssertEqual(try StartupBackfills.backfillParentLinks(db).linked, 0)
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'unconfined-child'")
            )
        }
    }

    func testQoderBackfillUsesDeclaredSymlinkProjectsRoot_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoder-symlink-root-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let store = root.appendingPathComponent("store", isDirectory: true)
        let realProjects = store.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".qoder", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: realProjects, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".qoder/projects"),
            withDestinationURL: realProjects
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = home.appendingPathComponent(".qoder/projects", isDirectory: true)
        let child = projectsRoot.appendingPathComponent("encoded/subagents/worker.jsonl")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"type":"user","sessionId":"qoder-symlink-parent"}"#
            .appending("\n")
            .write(to: child, atomically: true, encoding: .utf8)

        try writer.write { db in
            try insertSession(db, id: "qoder-symlink-parent", source: "qoder", tier: "normal")
            try insertSession(
                db,
                id: "qoder-symlink-child",
                source: "qoder",
                filePath: child.resolvingSymlinksInPath().path,
                agentRole: "subagent",
                tier: "skip"
            )

            XCTAssertFalse(child.resolvingSymlinksInPath().path.contains(".qoder"))
            XCTAssertFalse(child.resolvingSymlinksInPath().path.contains("projects"))
            XCTAssertEqual(
                try StartupBackfills.backfillParentLinks(db, homeDirectory: home).linked,
                1
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'qoder-symlink-child'"),
                "qoder-symlink-parent"
            )
        }
    }

    func testDerivedClaudeSourceBackfillUsesCustomProjectsRoot_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-custom-projects-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = root.appendingPathComponent("profiles/team/projects", isDirectory: true)
        let child = projectsRoot.appendingPathComponent("encoded/parent-id/subagents/worker.jsonl")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: child)
        let settingsURL = root.appendingPathComponent(".engram/settings.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
            {"claudeCodeProfiles":{"autoDiscover":false,"customProjectsRoots":["\(projectsRoot.path)"]}}
            """.write(to: settingsURL, atomically: true, encoding: .utf8)

        try writer.write { db in
            try insertSession(db, id: "parent-id", source: "minimax", tier: "normal")
            try insertSession(
                db,
                id: "minimax-child",
                source: "minimax",
                filePath: child.path,
                agentRole: "subagent",
                tier: "skip"
            )

            XCTAssertEqual(
                try StartupBackfills.backfillParentLinks(db, homeDirectory: root).linked,
                1
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'minimax-child'"),
                "parent-id"
            )
        }
    }

    func testQoderBackfillSkipsOversizedSniffLineAndFindsLaterSessionID_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoder-oversized-sniff-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent(".qoder/projects/encoded/subagents/worker.jsonl")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(repeating: 0x78, count: 8 * 1_024 * 1_024 + 1)
        data.append(0x0A)
        data.append(Data(#"{"type":"user","sessionId":"qoder-after-oversized"}"#.utf8))
        data.append(0x0A)
        try data.write(to: child)

        try writer.write { db in
            try insertSession(db, id: "qoder-after-oversized", source: "qoder", tier: "normal")
            try insertSession(
                db,
                id: "qoder-oversized-child",
                source: "qoder",
                filePath: child.path,
                agentRole: "subagent",
                tier: "skip"
            )

            XCTAssertEqual(
                try StartupBackfills.backfillParentLinks(db, homeDirectory: root).linked,
                1
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'qoder-oversized-child'"),
                "qoder-after-oversized"
            )
        }
    }

    func testQoderBackfillPrefersConfinedNestedPathParentOverTranscriptSessionId_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoder-nested-parent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appendingPathComponent(".qoder/projects", isDirectory: true)
        let childFile = projectsRoot.appendingPathComponent(
            "encoded-project/path-parent/subagents/agent.jsonl"
        )
        try FileManager.default.createDirectory(
            at: childFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"type":"user","sessionId":"different-session","message":{"role":"user","content":"work"}}"#
            .appending("\n")
            .write(to: childFile, atomically: true, encoding: .utf8)

        try writer.write { db in
            try insertSession(db, id: "path-parent", source: "qoder", tier: "normal")
            try insertSession(db, id: "different-session", source: "qoder", tier: "normal")
            try insertSession(
                db,
                id: "qoder-nested-child",
                source: "qoder",
                filePath: childFile.path,
                sourceLocator: childFile.path,
                agentRole: "subagent",
                tier: "skip"
            )

            XCTAssertEqual(
                try StartupBackfills.backfillParentLinks(db, homeDirectory: root).linked,
                1
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT parent_session_id FROM sessions WHERE id = 'qoder-nested-child'"
                ),
                "path-parent"
            )
        }
    }

    func testBackfillParentLinksUsesQoderProjectLevelJSONParent_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoder-project-parent-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent(".qoder/projects/encoded-project", isDirectory: true)
        let subagents = project.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parentId = "11111111-2222-3333-4444-555555555555"
        let child = subagents.appendingPathComponent("agent-worker.jsonl")
        try "{\"type\":\"user\",\"sessionId\":\"\(parentId)\"}\n"
            .write(to: child, atomically: true, encoding: .utf8)

        try writer.write { db in
            try insertSession(db, id: parentId, source: "qoder", tier: "normal")
            try insertSession(
                db,
                id: "qoder-child",
                source: "qoder",
                filePath: child.path,
                sourceLocator: child.path,
                agentRole: "subagent",
                tier: "skip"
            )

            let result = try StartupBackfills.backfillParentLinks(db, homeDirectory: root)

            XCTAssertEqual(result.linked, 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'qoder-child'"),
                parentId
            )
        }
    }

    /// R1/R2 P1 path-parent-unvalidated-no-reconcile: legacy non-manual path
    /// links may already be self-referential, dangling, depth>1, or point at a
    /// skip-tier parent. Startup must clear those links while preserving manual
    /// decisions and valid one-level links.
    func testBackfillParentLinksReconcilesIllegalPersistedPathParents_repro() throws {
        try writer.write { db in
            try insertSession(db, id: "root", source: "codex", tier: "normal")
            try insertSession(db, id: "skip-parent", source: "codex", tier: "skip")
            try insertSession(
                db,
                id: "nested-parent",
                source: "codex",
                tier: "normal",
                linkSource: "path",
                parentSessionId: "root"
            )
            try insertSession(
                db,
                id: "valid-child",
                source: "codex",
                filePath: "/tmp/root/subagents/valid.jsonl",
                agentRole: "subagent",
                tier: "skip",
                linkSource: "path",
                parentSessionId: "root"
            )
            try insertSession(
                db,
                id: "manual-dangling",
                source: "codex",
                filePath: "/tmp/missing-parent/subagents/manual.jsonl",
                agentRole: "subagent",
                tier: "skip",
                linkSource: "manual",
                parentSessionId: "missing-parent"
            )
            try insertSession(
                db,
                id: "path-parent-with-manual-child",
                source: "codex",
                tier: "normal",
                linkSource: "path",
                parentSessionId: "root"
            )
            try insertSession(
                db,
                id: "manual-child-under-path-parent",
                source: "codex",
                tier: "skip",
                linkSource: "manual",
                parentSessionId: "path-parent-with-manual-child"
            )
            for (child, parent) in [
                ("self-child", "self-child"),
                ("dangling-child", "missing-parent"),
                ("nested-child", "nested-parent"),
                ("skip-child", "skip-parent"),
            ] {
                try insertSession(
                    db,
                    id: child,
                    source: "codex",
                    filePath: "/tmp/\(parent)/subagents/worker.jsonl",
                    agentRole: "subagent",
                    tier: "skip",
                    linkSource: "path",
                    linkCheckedAt: "2026-08-23T12:00:00Z",
                    parentSessionId: parent
                )
            }

            _ = try StartupBackfills.backfillParentLinks(db)

            for child in ["self-child", "dangling-child", "nested-child", "skip-child"] {
                XCTAssertNil(
                    try String.fetchOne(
                        db,
                        sql: "SELECT parent_session_id FROM sessions WHERE id = ?",
                        arguments: [child]
                    ),
                    "\(child) must be restored to a visible top-level row"
                )
                XCTAssertNil(
                    try String.fetchOne(
                        db,
                        sql: "SELECT link_source FROM sessions WHERE id = ?",
                        arguments: [child]
                    )
                )
                XCTAssertEqual(
                    try String.fetchOne(
                        db,
                        sql: "SELECT link_checked_at FROM sessions WHERE id = ?",
                        arguments: [child]
                    ),
                    "2026-08-23T12:00:00Z",
                    "invalid path unlink must preserve a subagent classification stamp"
                )
            }
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'valid-child'"),
                "root"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'manual-dangling'"),
                "missing-parent",
                "startup reconcile must not override an explicit manual decision"
            )
            XCTAssertNil(
                try String.fetchOne(
                    db,
                    sql: "SELECT parent_session_id FROM sessions WHERE id = 'path-parent-with-manual-child'"
                ),
                "the path edge must yield to a manual child so the graph stays one level deep"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT parent_session_id FROM sessions WHERE id = 'manual-child-under-path-parent'"
                ),
                "path-parent-with-manual-child",
                "startup reconcile must preserve the manual edge"
            )
        }
    }

    // Audit PARENT-BACKFILL-STARVE-001: a single LIMIT 500 batch of unparseable
    // legacy subagent rows must not starve a later valid child in the same call.
    func testBackfillParentLinksDoesNotStarveValidChildBehindInvalidBatch_repro() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-parent-pagination-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = home.appendingPathComponent(".claude/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try writer.write { db in
            try insertSession(db, id: "real-parent", source: "claude-code", tier: "normal")
            for index in 0..<500 {
                try insertSession(
                    db,
                    id: String(format: "invalid-%03d", index),
                    source: "codex",
                    filePath: "/tmp/invalid-\(index)/no-subagent-path.jsonl",
                    agentRole: "subagent",
                    tier: "skip"
                )
            }
            try insertSession(
                db,
                id: "real-child",
                source: "claude-code",
                filePath: projectsRoot.appendingPathComponent("encoded/real-parent/subagents/worker.jsonl").path,
                agentRole: "subagent",
                tier: "skip"
            )

            let result = try StartupBackfills.backfillParentLinks(db, homeDirectory: home)
            XCTAssertEqual(result.linked, 1, "must paginate past 500 invalid candidates in one call")
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'real-child'"),
                "real-parent"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = 'real-child'"),
                "path"
            )
            XCTAssertNil(
                try String.fetchOne(
                    db,
                    sql: "SELECT parent_session_id FROM sessions WHERE id = 'invalid-000'"
                )
            )
        }
    }

    func testRunPeriodicParentBackfillsLinksAgentChildren() throws {
        let home = SessionAdapterFactory.resolvedHomeDirectory()
        let projectRoot = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent("periodic-\(UUID().uuidString)", isDirectory: true)
        let childPath = projectRoot.appendingPathComponent("parent-1/subagents/worker.jsonl").path
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        try writer.write { db in
            try insertSession(db, id: "parent-1", source: "claude-code", tier: "normal")
            try insertSession(
                db,
                id: "child-1",
                source: "claude-code",
                filePath: childPath,
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

    func testBackfillParentLinksRetriesGeminiSidecarAfterHostArrives_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-parent-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("transcript.json")
        let sidecar = root.appendingPathComponent("gemini-child.engram.json")
        try "{}".write(to: transcript, atomically: true, encoding: .utf8)
        try #"{"parentSessionId":"gemini-host"}"#.write(to: sidecar, atomically: true, encoding: .utf8)

        try writer.write { db in
            try insertSession(
                db,
                id: "gemini-child",
                source: "gemini-cli",
                filePath: transcript.path,
                agentRole: "dispatched",
                tier: "skip"
            )

            XCTAssertEqual(try StartupBackfills.backfillParentLinks(db).linked, 0)
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'gemini-child'")
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'gemini-child'"),
                "a sidecar whose host is not indexed yet must remain retryable"
            )

            try insertSession(db, id: "gemini-host", source: "claude-code", tier: "normal")

            XCTAssertEqual(try StartupBackfills.backfillParentLinks(db).linked, 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'gemini-child'"),
                "gemini-host"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = 'gemini-child'"),
                "path"
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

    // L11 / SUGGESTED-PARENT-RESCORE-001: a detection-version bump must
    // invalidate a stale single suggestion before the same startup pass scores
    // current candidates. Confirmed/manual links and skip classification stay put.
    func testDetectionVersionBumpResetsSingleSuggestedParentAndRescores_repro() async throws {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO metadata(key, value) VALUES ('detection_version', '5')")
            try insertSession(
                db,
                id: "wrong-parent",
                source: "claude-code",
                startTime: "2026-04-20T10:00:00.000Z",
                cwd: "/Users/bing/-Code-/old",
                project: "old",
                filePath: "/tmp/wrong-parent.jsonl"
            )
            try insertSession(
                db,
                id: "correct-parent",
                source: "claude-code",
                startTime: "2026-04-23T10:00:00.000Z",
                endTime: "2026-04-23T11:00:00.000Z",
                cwd: "/Users/bing/-Code-/engram",
                project: "engram",
                filePath: "/tmp/correct-parent.jsonl"
            )
            try insertSession(
                db,
                id: "confirmed-parent",
                source: "claude-code",
                startTime: "2026-04-19T10:00:00.000Z",
                filePath: "/tmp/confirmed-parent.jsonl"
            )
            try insertSession(
                db,
                id: "stale-child",
                source: "gemini-cli",
                startTime: "2026-04-23T10:10:00.000Z",
                cwd: "/Users/bing/-Code-/engram",
                project: "engram",
                filePath: "/tmp/stale-child.jsonl",
                agentRole: "dispatched",
                tier: "skip",
                linkCheckedAt: "2026-04-23T10:11:00.000Z",
                suggestionStatus: "suggested-v5",
                suggestionCandidates: "[{\"id\":\"wrong-parent\",\"score\":1}]",
                suggestedParentId: "wrong-parent"
            )
            try insertSession(
                db,
                id: "confirmed-child",
                source: "codex",
                filePath: "/tmp/confirmed-child.jsonl",
                agentRole: "subagent",
                tier: "skip",
                linkSource: "manual",
                linkCheckedAt: "2026-04-23T10:12:00.000Z",
                parentSessionId: "confirmed-parent"
            )
        }

        var events: [StartupBackfillEvent] = []
        let logger = RecordingStartupLogger()
        try await StartupBackfills.runStartupMaintenanceAndParents(
            indexed: 0,
            emit: { events.append($0) },
            log: logger,
            indexer: RecordingStartupIndexer(indexed: 0),
            database: WriterStartupBackfillDatabase(writer: writer, groupedDirRoots: { [] })
        )

        XCTAssertTrue(logger.warnings.isEmpty)
        XCTAssertTrue(
            events.contains(
                StartupBackfillEvent(
                    event: "backfill",
                    payload: ["type": .string("detection_reset"), "count": .int(1)]
                )
            )
        )
        try writer.read { db in
            let rescored = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                SELECT suggested_parent_id, suggestion_status, suggestion_candidates,
                       link_checked_at, agent_role, tier
                FROM sessions WHERE id = 'stale-child'
                """
            ))
            XCTAssertEqual(rescored["suggested_parent_id"] as String?, "correct-parent")
            XCTAssertNil(rescored["suggestion_status"] as String?)
            XCTAssertNil(rescored["suggestion_candidates"] as String?)
            XCTAssertNotNil(rescored["link_checked_at"] as String?)
            XCTAssertEqual(rescored["agent_role"] as String?, "dispatched")
            XCTAssertEqual(rescored["tier"] as String?, "skip")

            let confirmed = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                SELECT parent_session_id, link_source, link_checked_at, agent_role, tier
                FROM sessions WHERE id = 'confirmed-child'
                """
            ))
            XCTAssertEqual(confirmed["parent_session_id"] as String?, "confirmed-parent")
            XCTAssertEqual(confirmed["link_source"] as String?, "manual")
            XCTAssertEqual(confirmed["link_checked_at"] as String?, "2026-04-23T10:12:00.000Z")
            XCTAssertEqual(confirmed["agent_role"] as String?, "subagent")
            XCTAssertEqual(confirmed["tier"] as String?, "skip")
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'detection_version'"),
                "6"
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

    func testBackfillCodexOriginatorUsesCompleteSessionMetaBeforeMarkingChecked_repro() throws {
        let longClaudeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-long-originator-\(UUID().uuidString).jsonl")
        let malformedFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-malformed-originator-\(UUID().uuidString).jsonl")
        let longMeta = """
        {"type":"session_meta","payload":{"id":"codex-long","padding":"\(String(repeating: "界", count: 8_000))","originator":"Claude Code"}}
        """
        try (longMeta + "\n").write(to: longClaudeFile, atomically: true, encoding: .utf8)
        try #"{"type":"session_meta","payload":{"id":"broken""#
            .write(to: malformedFile, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: longClaudeFile)
            try? FileManager.default.removeItem(at: malformedFile)
        }

        try writer.write { db in
            try insertSession(db, id: "codex-long", source: "codex", filePath: longClaudeFile.path)
            try insertSession(db, id: "codex-malformed", source: "codex", filePath: malformedFile.path)

            XCTAssertEqual(try StartupBackfills.backfillCodexOriginator(db), 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'codex-long'"),
                "dispatched"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'codex-malformed'"),
                "An incomplete session_meta must remain eligible for a later complete read."
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
            try insertSemanticChunk(db, sessionId: "codex-claude", text: leaked)
            try insertSemanticChunk(db, sessionId: "codex-native", text: kept)

            // PR #141 and EMB-001 regressions: per-session skip classification
            // must purge cached messages, FTS, and both embedding stores.
            let updated = try StartupBackfills.backfillCodexOriginator(db)

            XCTAssertEqual(updated, 1)
            try assertRecoverableArtifactContent(db, content: leaked, expectedCount: 0)
            try assertRecoverableArtifactContent(db, content: kept, expectedCount: 4)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_chunks WHERE session_id = 'codex-claude'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_chunks WHERE session_id = 'codex-native'"),
                1
            )
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

    func testBackfillCodexModelLabelsDecodesCompleteLinesBeforeUTF8Boundary_repro() throws {
        let rollout = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-model-boundary-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: rollout) }

        let meta = #"{"type":"session_meta","payload":{"id":"boundary-model"}}"#
        let turn = #"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#
        var data = Data("\(meta)\n\(turn)\n".utf8)
        let boundary = StartupBackfills.codexModelHeadScanBytes
        data.append(contentsOf: Array(repeating: UInt8(ascii: "x"), count: boundary - 2 - data.count))
        data.append(contentsOf: [0xE2, 0x9C, 0x93])
        try data.write(to: rollout)
        XCTAssertNil(String(data: data.prefix(boundary), encoding: .utf8))

        try writer.write { db in
            try insertSession(db, id: "boundary-model", source: "codex", filePath: rollout.path, model: "openai")

            XCTAssertEqual(try StartupBackfills.backfillCodexModelLabels(db), 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT model FROM sessions WHERE id = 'boundary-model'"),
                "gpt-5.5"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'codex_model_backfill_version'"),
                StartupBackfills.codexModelBackfillVersion
            )
        }
    }

    func testBackfillCodexModelLabelsRetriesUnreadableHeadsBeforeStampingVersion_repro() throws {
        let rollout = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-model-retry-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: rollout) }

        try writer.write { db in
            try insertSession(db, id: "retry-model", source: "codex", filePath: rollout.path, model: "openai")

            XCTAssertEqual(try StartupBackfills.backfillCodexModelLabels(db), 0)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT model FROM sessions WHERE id = 'retry-model'"),
                "openai"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'codex_model_backfill_version'")
            )

            let line = #"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"# + "\n"
            try line.write(to: rollout, atomically: true, encoding: .utf8)

            XCTAssertEqual(try StartupBackfills.backfillCodexModelLabels(db), 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT model FROM sessions WHERE id = 'retry-model'"),
                "gpt-5.5"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'codex_model_backfill_version'"),
                StartupBackfills.codexModelBackfillVersion
            )
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

            XCTAssertEqual(result, StartupBackfills.ProviderParentResult(checked: 2, classified: 2, suggested: 2))
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

    func testBackfillPolycliProviderParentsDrainsAllCandidatePages_repro() throws {
        try writer.write { db in
            try db.execute(sql: """
                WITH RECURSIVE seq(n) AS (
                  VALUES(0)
                  UNION ALL
                  SELECT n + 1 FROM seq WHERE n < 1000
                )
                INSERT INTO sessions(id, source, start_time, end_time, cwd, summary, file_path)
                SELECT printf('qwen-probe-%04d', n),
                       'qwen',
                       '2026-05-08T10:00:00.000Z',
                       '2026-05-08T10:01:00.000Z',
                       '',
                       'ping',
                       printf('/tmp/qwen-probe-%04d.jsonl', n)
                FROM seq
                """)

            let result = try StartupBackfills.backfillPolycliProviderParents(db)

            XCTAssertEqual(result.checked, 1001)
            XCTAssertEqual(result.classified, 1001)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE tier = 'skip'"),
                1001
            )
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

    func testBackfillPolycliDoesNotStealNonProbeReviewFromLaterParentDetection_repro() throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "gemini-review-task",
                source: "gemini-cli",
                startTime: "2026-08-21T00:00:00.000Z",
                cwd: "/repo",
                summary: "Review the adapter behavior and explain the current implementation."
            )

            let result = try StartupBackfills.backfillPolycliProviderParents(db)

            XCTAssertEqual(result.classified, 0)
            XCTAssertNil(
                try String.fetchOne(
                    db,
                    sql: "SELECT link_checked_at FROM sessions WHERE id = 'gemini-review-task'"
                ),
                "a non-probe review must remain eligible for the later parent-detection layer"
            )
        }
    }

    func testBackfillPolycliRequiresStrongReviewProbeMarker_repro() throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "qwen-weak-review",
                source: "qwen",
                startTime: "2026-08-21T00:00:00.000Z",
                cwd: "/repo",
                summary: "Review P2 tests for correctness and summarize the result."
            )

            let result = try StartupBackfills.backfillPolycliProviderParents(db)

            XCTAssertEqual(result.classified, 0)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'qwen-weak-review'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'qwen-weak-review'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'qwen-weak-review'"))
        }
    }

    func testBackfillPolycliRejectsClaudeProbesGrownSessionsAndRowsWithChildren_repro() throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "claude-ping",
                source: "claude-code",
                summary: "ping",
                userMessageCount: 1,
                assistantMessageCount: 1
            )
            try insertSession(
                db,
                id: "qwen-grown-ping",
                source: "qwen",
                summary: "ping",
                userMessageCount: 2,
                assistantMessageCount: 2
            )
            try insertSession(
                db,
                id: "qwen-parent-ping",
                source: "qwen",
                summary: "ping",
                userMessageCount: 1,
                assistantMessageCount: 1
            )
            try insertSession(
                db,
                id: "existing-child",
                source: "codex",
                parentSessionId: "qwen-parent-ping"
            )
            try insertSession(
                db,
                id: "claude-polycli",
                source: "claude-code",
                summary: "You are acting as reviewer_1 inside polycli. Report findings.",
                userMessageCount: 10,
                assistantMessageCount: 10
            )

            let result = try StartupBackfills.backfillPolycliProviderParents(db)

            XCTAssertEqual(result.classified, 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'claude-polycli'"),
                "dispatched"
            )
            for id in ["claude-ping", "qwen-grown-ping", "qwen-parent-ping"] {
                XCTAssertNil(
                    try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = ?", arguments: [id]),
                    "\(id) must remain a human/root session"
                )
                XCTAssertNil(
                    try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = ?", arguments: [id])
                )
                XCTAssertNil(
                    try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = ?", arguments: [id])
                )
            }
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

            // Wave 7B M18: ordinary same-cwd sessions are not admitted without
            // probe/dispatch summary evidence, so only ping + review probes count.
            XCTAssertEqual(first.classified, 2)
            XCTAssertEqual(second, StartupBackfills.ProviderParentResult(checked: 0, classified: 0, suggested: 0))
            XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'qwen-linked'"))
            XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'kimi-unlinked'"))
            // Ordinary non-probe is never a Polycli candidate under M18.
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'qwen-ordinary'"))
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

    func testBackfillSuggestedParentsRejectsSkipAndNestedHostCandidates_repro() throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "valid-parent",
                source: "claude-code",
                startTime: "2026-04-23T10:00:00.000Z",
                cwd: "/repo",
                project: "engram"
            )
            try insertSession(
                db,
                id: "agent",
                source: "gemini-cli",
                startTime: "2026-04-23T10:10:00.000Z",
                cwd: "/repo",
                project: "engram",
                summary: "Your task is to audit the repo"
            )
            try insertSession(
                db,
                id: "nested-host",
                source: "gemini-cli",
                parentSessionId: "agent"
            )

            let result = try StartupBackfills.backfillSuggestedParents(db)

            XCTAssertEqual(result.suggested, 0)
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'agent'"),
                "A session that already owns children must not become a suggested child."
            )
            XCTAssertNotNil(
                try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'agent'")
            )
        }

        try writer.write { db in
            try db.execute(sql: "DELETE FROM sessions")
            try insertSession(
                db,
                id: "skip-parent",
                source: "claude-code",
                startTime: "2026-04-23T10:09:00.000Z",
                cwd: "/repo",
                project: "engram",
                tier: "skip"
            )
            try insertSession(
                db,
                id: "valid-parent",
                source: "claude-code",
                startTime: "2026-04-23T10:00:00.000Z",
                cwd: "/repo",
                project: "engram"
            )
            try insertSession(
                db,
                id: "agent",
                source: "gemini-cli",
                startTime: "2026-04-23T10:10:00.000Z",
                cwd: "/repo",
                project: "engram",
                summary: "Your task is to audit the repo"
            )

            XCTAssertEqual(try StartupBackfills.backfillSuggestedParents(db).suggested, 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'agent'"),
                "valid-parent"
            )
        }
    }

    func testBackfillSuggestedParentsClearsSuggestionsToHiddenSkipOrOrphanHosts_repro() throws {
        try writer.write { db in
            for suffix in ["hidden", "skip", "orphan"] {
                try insertSession(db, id: "host-\(suffix)", source: "claude-code")
                try insertSession(db, id: "child-\(suffix)", source: "gemini-cli", tier: "normal")
                try db.execute(
                    sql: "UPDATE sessions SET suggested_parent_id = ?, link_checked_at = 'checked' WHERE id = ?",
                    arguments: ["host-\(suffix)", "child-\(suffix)"]
                )
            }
            try db.execute(sql: "UPDATE sessions SET hidden_at = '2026-08-24T00:00:00Z' WHERE id = 'host-hidden'")
            try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'host-skip'")
            try db.execute(sql: "UPDATE sessions SET orphan_status = 'suspect' WHERE id = 'host-orphan'")

            _ = try StartupBackfills.backfillSuggestedParents(db)

            for suffix in ["hidden", "skip", "orphan"] {
                XCTAssertNil(
                    try String.fetchOne(
                        db,
                        sql: "SELECT suggested_parent_id FROM sessions WHERE id = ?",
                        arguments: ["child-\(suffix)"]
                    )
                )
                XCTAssertEqual(
                    try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = ?", arguments: ["child-\(suffix)"]),
                    "normal"
                )
            }
        }
    }

    func testBackfillSuggestedParentsRescoresAfterDeadSuggestedHostCleanup_repro() throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "dead-host",
                source: "claude-code",
                startTime: "2026-04-23T09:00:00.000Z",
                cwd: "/repo",
                project: "engram"
            )
            try insertSession(
                db,
                id: "live-host",
                source: "claude-code",
                startTime: "2026-04-23T10:00:00.000Z",
                cwd: "/repo",
                project: "engram"
            )
            try insertSession(
                db,
                id: "stale-child",
                source: "gemini-cli",
                startTime: "2026-04-23T10:10:00.000Z",
                cwd: "/repo",
                project: "engram",
                summary: "Your task is to review the implementation",
                tier: "normal",
                linkCheckedAt: "2026-04-23T10:11:00.000Z",
                suggestedParentId: "dead-host"
            )
            try db.execute(
                sql: "UPDATE sessions SET hidden_at = '2026-04-23T10:12:00.000Z' WHERE id = 'dead-host'"
            )

            let result = try StartupBackfills.backfillSuggestedParents(db)

            XCTAssertEqual(result.suggested, 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'stale-child'"),
                "live-host"
            )
            XCTAssertNotNil(
                try String.fetchOne(db, sql: "SELECT link_checked_at FROM sessions WHERE id = 'stale-child'")
            )
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

    func testBackfillSuggestedParentsPrunesDeadAmbiguousCandidates_repro() throws {
        try writer.write { db in
            for id in ["live-a", "live-b"] {
                try insertSession(db, id: id, source: "claude-code", tier: "normal")
            }
            try insertSession(db, id: "hidden-host", source: "claude-code", tier: "normal")
            try db.execute(
                sql: "UPDATE sessions SET hidden_at = '2026-04-23T10:00:00.000Z' WHERE id = 'hidden-host'"
            )

            try insertSession(
                db,
                id: "ambiguous-zero",
                source: "codex",
                tier: "normal",
                linkCheckedAt: "2026-04-23T10:01:00.000Z",
                suggestionStatus: "ambiguous",
                suggestionCandidates: "[{\"id\":\"missing-host\",\"score\":9},{\"id\":\"hidden-host\",\"score\":8}]"
            )
            try insertSession(
                db,
                id: "ambiguous-one",
                source: "codex",
                tier: "normal",
                linkCheckedAt: "2026-04-23T10:01:00.000Z",
                suggestionStatus: "ambiguous",
                suggestionCandidates: "[{\"id\":\"live-a\",\"score\":9},{\"id\":\"hidden-host\",\"score\":8}]"
            )
            try insertSession(
                db,
                id: "ambiguous-two",
                source: "codex",
                tier: "normal",
                linkCheckedAt: "2026-04-23T10:01:00.000Z",
                suggestionStatus: "ambiguous",
                suggestionCandidates: "[{\"id\":\"live-a\",\"score\":9},{\"id\":\"hidden-host\",\"score\":8},{\"id\":\"live-b\",\"score\":7}]"
            )

            _ = try StartupBackfills.backfillSuggestedParents(db)

            let zero = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT suggested_parent_id, suggestion_status, suggestion_candidates, link_checked_at FROM sessions WHERE id = 'ambiguous-zero'"
            ))
            XCTAssertNil(zero["suggested_parent_id"] as String?)
            XCTAssertNil(zero["suggestion_status"] as String?)
            XCTAssertNil(zero["suggestion_candidates"] as String?)
            XCTAssertNotNil(zero["link_checked_at"] as String?)

            let one = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT suggested_parent_id, suggestion_status, suggestion_candidates FROM sessions WHERE id = 'ambiguous-one'"
            ))
            XCTAssertEqual(one["suggested_parent_id"] as String?, "live-a")
            XCTAssertNil(one["suggestion_status"] as String?)
            XCTAssertNil(one["suggestion_candidates"] as String?)

            let two = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT suggested_parent_id, suggestion_status, suggestion_candidates FROM sessions WHERE id = 'ambiguous-two'"
            ))
            XCTAssertNil(two["suggested_parent_id"] as String?)
            XCTAssertEqual(two["suggestion_status"] as String?, "ambiguous")
            let encoded = try XCTUnwrap(two["suggestion_candidates"] as String?)
            let candidates = try JSONDecoder().decode(
                [StoredAmbiguousCandidate].self,
                from: Data(encoded.utf8)
            )
            XCTAssertEqual(candidates.map(\.id), ["live-a", "live-b"])
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
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'late-agent'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = 'late-agent'"))
        }
    }

    func testGeminiCliDispatchPatternWithoutParentDoesNotSkipTier_repro() throws {
        try writer.write { db in
            let leaked = "gemini-human-analyze-drift"
            try insertSession(
                db, id: "gemini-human", source: "gemini-cli",
                startTime: "2026-04-23T10:10:00.000Z",
                cwd: "/Users/bing/-Code-/engram", project: "engram",
                summary: "Analyze the adapter implementation for drift"
            )
            try createRecoverableArtifactTables(db)
            try insertRecoverableArtifacts(db, sessionId: "gemini-human", content: leaked)
            let result = try StartupBackfills.backfillSuggestedParents(db)
            XCTAssertEqual(result.checked, 1)
            XCTAssertEqual(result.suggested, 0)
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT agent_role, tier, link_checked_at FROM sessions WHERE id = 'gemini-human'
            """))
            XCTAssertNil(row["agent_role"] as String?)
            XCTAssertNil(row["tier"] as String?)
            XCTAssertNotNil(row["link_checked_at"] as String?)
            try assertRecoverableArtifactContent(db, content: leaked, expectedCount: 4)
        }
    }

    func testBackfillSuggestedParentsDrainsAllCandidatePages_repro() throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "drain-parent",
                source: "claude-code",
                startTime: "2026-04-23T09:00:00.000Z",
                cwd: "/repo",
                project: "engram"
            )
            for index in 0..<500 {
                try insertSession(
                    db,
                    id: String(format: "ordinary-%03d", index),
                    source: "gemini-cli",
                    startTime: "2026-04-23T10:00:00.000Z"
                )
            }
            try insertSession(
                db,
                id: "drain-child",
                source: "gemini-cli",
                startTime: "2026-04-23T10:00:00.000Z",
                cwd: "/repo",
                project: "engram",
                summary: "Your task is to audit the repository"
            )

            let result = try StartupBackfills.backfillSuggestedParents(db)

            XCTAssertEqual(result.checked, 501)
            XCTAssertEqual(result.suggested, 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'drain-child'"),
                "drain-parent"
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
                "reconcileInsights",
                "reconcileGroupedSourceDirs",
                "backfillFilePaths",
                "downgradeSubagentTiers",
                "backfillParentLinks",
                "backfillCodexNativeParents",
                "resetStaleDetections",
                "backfillCodexOriginator",
                "backfillPolycliProviderParents",
                "backfillSuggestedParents",
                "cleanupStaleMigrations",
                "countSessions",
                "countTodayParentSessions",
                "backfillParentLinks",
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
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("codex_native_parents"), "linked": .int(42)]),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("detection_reset"), "count": .int(11)]),
                StartupBackfillEvent(event: "backfill", payload: ["type": .string("codex_originator"), "updated": .int(12)]),
                StartupBackfillEvent(
                    event: "backfill",
                    payload: [
                        "type": .string("polycli_provider_parents"),
                        "checked": .int(26),
                        "classified": .int(27),
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

    func testGroupedDirectoryReconcileRunsOncePerVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grouped-reconcile-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let cwd = "/Users/bing/-Code-/engram"
        let stale = root.appendingPathComponent("stale", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("{\"cwd\":\"\(cwd)\"}\n".utf8).write(
            to: stale.appendingPathComponent("session.jsonl")
        )
        let sourceRoot = SourceRoot(
            id: .claudeCode,
            path: root.path,
            encodeProjectDir: { ClaudeCodeProjectDir.encode($0) }
        )
        let database = WriterStartupBackfillDatabase(
            writer: writer,
            groupedDirRoots: { [sourceRoot] }
        )

        let first = try database.reconcileGroupedSourceDirs()
        XCTAssertEqual(first.appliedRenames, 1)
        XCTAssertEqual(
            try writer.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT value FROM metadata WHERE key = ?",
                    arguments: [StartupBackfills.groupedDirReconcileMetadataKey]
                )
            },
            StartupBackfills.groupedDirReconcileVersion
        )

        let secondStale = root.appendingPathComponent("second-stale", isDirectory: true)
        try FileManager.default.createDirectory(at: secondStale, withIntermediateDirectories: true)
        try Data("{\"cwd\":\"/Users/bing/-Code-/other\"}\n".utf8).write(
            to: secondStale.appendingPathComponent("session.jsonl")
        )

        XCTAssertEqual(try database.reconcileGroupedSourceDirs(), GroupedDirReconcileResult())
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondStale.path))
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

    func testStartupOrphanScanReconcilesPathLinksAfterTransitions_repro() async throws {
        let database = RecordingStartupDatabase()

        try await StartupBackfills.runStartupOrphanScan(
            emit: { _ in },
            log: RecordingStartupLogger(),
            orphanScanner: RecordingStartupOrphanScanner(
                scanned: 1,
                newlyFlagged: 1,
                confirmed: 0,
                recovered: 0,
                skipped: 0
            ),
            database: database,
            adapters: []
        )

        XCTAssertEqual(
            database.callOrder.filter { $0 == "backfillParentLinks" },
            ["backfillParentLinks"],
            "path-link cleanup must run after orphan state changes"
        )
        XCTAssertLessThan(
            try XCTUnwrap(database.callOrder.firstIndex(of: "backfillParentLinks")),
            try XCTUnwrap(database.callOrder.firstIndex(of: "enqueueStaleFtsJobs"))
        )
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

    func testDeduplicateFilePathsRemovesOrphanedRebuildRows_repro() throws {
        try writer.write { db in
            try insertSession(db, id: "old-shadow", source: "codex", filePath: "/tmp/dup-shadow.jsonl")
            try insertSession(db, id: "new-shadow", source: "codex", filePath: "/tmp/dup-shadow.jsonl")
            try db.execute(sql: "CREATE VIRTUAL TABLE sessions_fts_rebuild USING fts5(session_id UNINDEXED, content)")
            try db.execute(sql: """
                INSERT INTO sessions_fts_rebuild(session_id, content)
                VALUES ('old-shadow', 'stale shadow'), ('new-shadow', 'kept shadow')
                """)

            XCTAssertEqual(try StartupBackfills.deduplicateFilePaths(db), 1)

            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts_rebuild WHERE session_id = 'old-shadow'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts_rebuild WHERE session_id = 'new-shadow'"),
                1
            )
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

    func testDeduplicateFilePathsRemapsRelatedSessionBeforeDeletingDuplicate_repro() throws {
        try writer.write { db in
            try insertSession(db, id: "old", source: "codex", filePath: "/tmp/related-dup.jsonl")
            try insertSession(db, id: "new", source: "codex", filePath: "/tmp/related-dup.jsonl")
            try insertSession(db, id: "peer", source: "codex", filePath: "/tmp/related-peer.jsonl")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS session_relations (
                  a_id TEXT NOT NULL,
                  b_id TEXT NOT NULL,
                  created_at TEXT NOT NULL DEFAULT (datetime('now')),
                  PRIMARY KEY (a_id, b_id)
                );
                INSERT INTO session_relations(a_id, b_id) VALUES ('old', 'peer');
                """)

            XCTAssertEqual(try StartupBackfills.deduplicateFilePaths(db), 1)

            XCTAssertEqual(
                try Row.fetchAll(db, sql: "SELECT a_id, b_id FROM session_relations").map {
                    [String($0["a_id"] as String), String($0["b_id"] as String)]
                },
                [["new", "peer"]]
            )
        }
    }

    func testMigratedSessionRelationsCascadeWhenEitherSessionIsDeleted_repro() throws {
        try writer.write { db in
            try insertSession(db, id: "left", source: "codex", filePath: "/tmp/relation-left.jsonl")
            try insertSession(db, id: "right", source: "codex", filePath: "/tmp/relation-right.jsonl")

            let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(session_relations)")
            XCTAssertEqual(foreignKeys.count, 2)
            XCTAssertEqual(Set(foreignKeys.compactMap { $0["on_delete"] as String? }), ["CASCADE"])

            try db.execute(sql: "INSERT INTO session_relations(a_id, b_id) VALUES ('left', 'right')")
            try db.execute(sql: "DELETE FROM sessions WHERE id = 'right'")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_relations"), 0)
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

    func testSessionDeleteTriggerPreservesExistingChildTiers_repro() throws {
        try writer.write { db in
            try insertSession(db, id: "parent", source: "codex", filePath: "/tmp/parent.jsonl")
            try insertSession(db, id: "confirmed-lite", source: "codex", filePath: "/tmp/confirmed-lite.jsonl", tier: "lite")
            try insertSession(db, id: "suggested-skip", source: "codex", filePath: "/tmp/suggested-skip.jsonl", tier: "skip")
            try db.execute(
                sql: "UPDATE sessions SET parent_session_id = 'parent', link_source = 'manual' WHERE id = 'confirmed-lite'"
            )
            try db.execute(
                sql: "UPDATE sessions SET suggested_parent_id = 'parent' WHERE id = 'suggested-skip'"
            )

            try db.execute(sql: "DELETE FROM sessions WHERE id = 'parent'")

            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'confirmed-lite'")
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'suggested-skip'")
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'confirmed-lite'"),
                "lite"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = 'suggested-skip'"),
                "skip"
            )
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

    // Round 2 / P1 multi-phase-commit-split: once Phase B durably records
    // fs_done and the destination is the only surviving project path, startup
    // must finish the idempotent DB rewrite instead of waiting 24h and failing
    // the durable recovery intent.
    func testCleanupStaleMigrationsRecoversProvableFsDoneMove_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-project-move-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPath = root.appendingPathComponent("old-project", isDirectory: true).path
        let newPath = root.appendingPathComponent("new-project", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: newPath, withIntermediateDirectories: true)

        try writer.write { db in
            try insertSession(
                db,
                id: "recover-fs-done",
                source: "codex",
                cwd: "\(oldPath)/workspace",
                filePath: "\(oldPath)/session.jsonl",
                sourceLocator: "\(oldPath)/session.jsonl"
            )
            try db.execute(
                sql: "INSERT INTO session_local_state(session_id, local_readable_path) VALUES (?, ?)",
                arguments: ["recover-fs-done", "\(oldPath)/session.jsonl"]
            )
            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: "recover-fs-done",
                    oldPath: oldPath,
                    newPath: newPath,
                    oldBasename: "old-project",
                    newBasename: "new-project"
                )
            )
            try MigrationLogStore.markFsDone(
                db,
                input: MarkFsDoneInput(
                    id: "recover-fs-done",
                    filesPatched: 1,
                    occurrences: 3,
                    ccDirRenamed: false,
                    detail: ["startup_recovery": .string("ready")]
                )
            )

            XCTAssertEqual(try StartupBackfills.cleanupStaleMigrations(db), 0)
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT state FROM migration_log WHERE id = 'recover-fs-done'"
                ),
                "committed"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT cwd FROM sessions WHERE id = 'recover-fs-done'"),
                "\(newPath)/workspace"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT local_readable_path FROM session_local_state WHERE session_id = 'recover-fs-done'"
                ),
                "\(newPath)/session.jsonl"
            )
        }
    }

    // Rows written before the durable recovery disposition existed are
    // ambiguous: an old process may have started compensation but failed to
    // persist state='failed'. Do not auto-commit those legacy rows.
    func testCleanupStaleMigrationsDoesNotRecoverUnmarkedFsDoneMove_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-project-move-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPath = root.appendingPathComponent("old-project", isDirectory: true).path
        let newPath = root.appendingPathComponent("new-project", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: newPath, withIntermediateDirectories: true)

        try writer.write { db in
            try insertSession(db, id: "legacy-fs-done", source: "codex", cwd: "\(oldPath)/workspace")
            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: "legacy-fs-done",
                    oldPath: oldPath,
                    newPath: newPath,
                    oldBasename: "old-project",
                    newBasename: "new-project"
                )
            )
            try MigrationLogStore.markFsDone(
                db,
                input: MarkFsDoneInput(
                    id: "legacy-fs-done",
                    filesPatched: 1,
                    occurrences: 1,
                    ccDirRenamed: false
                )
            )

            XCTAssertEqual(try StartupBackfills.cleanupStaleMigrations(db), 0)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT state FROM migration_log WHERE id = 'legacy-fs-done'"),
                "fs_done"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT cwd FROM sessions WHERE id = 'legacy-fs-done'"),
                "\(oldPath)/workspace"
            )
        }
    }

    // A second crash can happen after an error path durably announces that it
    // is about to compensate Phase B. Even if old/new currently resembles a
    // completed move, startup must leave that interrupted compensation alone.
    func testCleanupStaleMigrationsDoesNotRecoverCompensatingFsDoneMove_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-project-move-compensating-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPath = root.appendingPathComponent("old-project", isDirectory: true).path
        let newPath = root.appendingPathComponent("new-project", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: newPath, withIntermediateDirectories: true)

        try writer.write { db in
            try insertSession(db, id: "compensating-fs-done", source: "codex", cwd: "\(oldPath)/workspace")
            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: "compensating-fs-done",
                    oldPath: oldPath,
                    newPath: newPath,
                    oldBasename: "old-project",
                    newBasename: "new-project"
                )
            )
            try MigrationLogStore.markFsDone(
                db,
                input: MarkFsDoneInput(
                    id: "compensating-fs-done",
                    filesPatched: 1,
                    occurrences: 1,
                    ccDirRenamed: false,
                    detail: ["startup_recovery": .string("compensating")]
                )
            )

            XCTAssertEqual(try StartupBackfills.cleanupStaleMigrations(db), 0)
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT state FROM migration_log WHERE id = 'compensating-fs-done'"
                ),
                "fs_done"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT cwd FROM sessions WHERE id = 'compensating-fs-done'"),
                "\(oldPath)/workspace"
            )
        }
    }

    // A failed Phase C can compensate the filesystem before its best-effort
    // failMigration write succeeds. Preserve that fs_done row for diagnosis
    // when disk state proves the move was rolled back.
    func testCleanupStaleMigrationsDoesNotRecoverCompensatedFsDoneMove_repro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-project-move-compensated-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPath = root.appendingPathComponent("old-project", isDirectory: true).path
        let newPath = root.appendingPathComponent("new-project", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: oldPath, withIntermediateDirectories: true)

        try writer.write { db in
            try insertSession(
                db,
                id: "compensated-fs-done",
                source: "codex",
                cwd: "\(oldPath)/workspace"
            )
            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: "compensated-fs-done",
                    oldPath: oldPath,
                    newPath: newPath,
                    oldBasename: "old-project",
                    newBasename: "new-project"
                )
            )
            try MigrationLogStore.markFsDone(
                db,
                input: MarkFsDoneInput(
                    id: "compensated-fs-done",
                    filesPatched: 1,
                    occurrences: 1,
                    ccDirRenamed: false
                )
            )

            XCTAssertEqual(try StartupBackfills.cleanupStaleMigrations(db), 0)
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT state FROM migration_log WHERE id = 'compensated-fs-done'"
                ),
                "fs_done"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT cwd FROM sessions WHERE id = 'compensated-fs-done'"),
                "\(oldPath)/workspace"
            )
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

    func testOrphanScanSkipsRemoteImportedRows_repro() async throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "remote-origin",
                source: "codex",
                filePath: "/files/imported.jsonl"
            )
            try db.execute(sql: "UPDATE sessions SET origin = 'hq' WHERE id = 'remote-origin'")
            try insertSession(
                db,
                id: "remote-locator",
                source: "codex",
                filePath: "remote://hq/native-session"
            )
            try insertSession(db, id: "local-missing", source: "codex", filePath: "/files/local.jsonl")
        }

        let adapter = FakeAccessibilityAdapter(accessibleLocators: [])
        let scanner = WriterStartupOrphanScanning(writer: writer, minimumScanInterval: 0)

        let result = try await scanner.detectOrphans(adapters: [adapter])

        XCTAssertEqual(result.scanned, 1, "only the local filesystem row belongs in an orphan scan")
        XCTAssertEqual(result.newlyFlagged, 1)
        XCTAssertEqual(adapter.probedLocators, ["/files/local.jsonl"])
        try writer.read { db in
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT orphan_status FROM sessions WHERE id = 'remote-origin'"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT orphan_status FROM sessions WHERE id = 'remote-locator'"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT orphan_status FROM sessions WHERE id = 'local-missing'"),
                "suspect"
            )
        }
    }

    func testOrphanScanBackfillsPreviouslyMarkedRemoteRowsOnce_repro() async throws {
        try writer.write { db in
            try insertSession(
                db,
                id: "remote-suspect",
                source: "codex",
                filePath: "remote://hq/native-suspect"
            )
            try db.execute(
                sql: """
                UPDATE sessions
                SET origin = 'hq', orphan_status = 'suspect',
                    orphan_since = datetime('now', '-2 days'), orphan_reason = 'path_unreachable'
                WHERE id = 'remote-suspect';
                INSERT INTO metadata(key, value) VALUES ('last_orphan_scan', datetime('now'));
                """
            )
        }

        let scanner = WriterStartupOrphanScanning(writer: writer)

        let first = try await scanner.detectOrphans(adapters: [FakeAccessibilityAdapter(accessibleLocators: [])])

        XCTAssertEqual(first.recovered, 1, "the one-time repair must run even when the filesystem scan is interval-gated")
        try writer.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT orphan_status, orphan_since, orphan_reason FROM sessions WHERE id = 'remote-suspect'"
            )
            XCTAssertNil(row?["orphan_status"] as String?)
            XCTAssertNil(row?["orphan_since"] as String?)
            XCTAssertNil(row?["orphan_reason"] as String?)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'remote_orphan_reconcile_version'"),
                "1"
            )
        }

        let second = try await scanner.detectOrphans(adapters: [FakeAccessibilityAdapter(accessibleLocators: [])])
        XCTAssertEqual(second.recovered, 0, "the versioned repair must be idempotent")
    }

    func testEnqueueStaleFtsJobsAddsPendingJobForCurrentSnapshotHash() throws {
        try writer.write { db in
            try insertSession(db, id: "stale", source: "codex", tier: "normal")
            try insertSession(db, id: "fresh", source: "codex", tier: "normal")
            try insertSession(db, id: "skip", source: "codex", tier: "skip")
            try db.execute(sql: "UPDATE sessions SET sync_version = 1, snapshot_hash = 'current' WHERE id IN ('stale', 'fresh', 'skip')")
            try db.execute(
                sql: """
                INSERT INTO sessions_fts(session_id, content)
                VALUES ('fresh', 'current searchable content');
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

    func testEnqueueStaleFtsJobsReopensCurrentCompletedJobWhenFtsRowIsMissing_repro() throws {
        try writer.write { db in
            try insertSession(db, id: "hole", source: "codex", filePath: "/tmp/hole.jsonl", tier: "normal")
            try insertSession(db, id: "skip-hole", source: "codex", filePath: "/tmp/skip.jsonl", tier: "skip")
            try insertSession(db, id: "no-locator", source: "codex", filePath: "", tier: "normal")
            try db.execute(
                sql: """
                UPDATE sessions
                SET sync_version = 1, snapshot_hash = 'current'
                WHERE id IN ('hole', 'skip-hole', 'no-locator');
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
                VALUES
                  ('hole:1:current:fts', 'hole', 'fts', 1, 'completed'),
                  ('skip-hole:1:current:fts', 'skip-hole', 'fts', 1, 'completed'),
                  ('no-locator:1:current:fts', 'no-locator', 'fts', 1, 'completed');
                """
            )

            XCTAssertEqual(try StartupBackfills.enqueueStaleFtsJobs(db), 1)
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT session_id FROM session_index_jobs WHERE status = 'pending' ORDER BY session_id"
                ),
                ["hole"]
            )
        }
    }

    func testEnqueueStaleFtsJobsDoesNotReopenFailedPermanentHole_repro() throws {
        try writer.write { db in
            for id in ["completed", "not-applicable", "permanent", "missing-job", "skip-hole"] {
                try insertSession(
                    db,
                    id: id,
                    source: "codex",
                    filePath: "/tmp/\(id).jsonl",
                    tier: id == "skip-hole" ? "skip" : "normal"
                )
            }
            try db.execute(sql: """
                UPDATE sessions SET sync_version = 1, snapshot_hash = 'current';
                INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status)
                VALUES
                  ('completed:1:current:fts', 'completed', 'fts', 1, 'completed'),
                  ('not-applicable:1:current:fts', 'not-applicable', 'fts', 1, 'not_applicable'),
                  ('permanent:1:current:fts', 'permanent', 'fts', 1, 'failed_permanent'),
                  ('skip-hole:1:current:fts', 'skip-hole', 'fts', 1, 'failed_permanent');
                """)

            XCTAssertEqual(try StartupBackfills.enqueueStaleFtsJobs(db), 3)
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT session_id FROM session_index_jobs WHERE status = 'pending' ORDER BY session_id"
                ),
                ["completed", "missing-job", "not-applicable"]
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT status FROM session_index_jobs WHERE session_id = 'permanent'"
                ),
                "failed_permanent"
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

    func testInProgressFtsMergeContinuesBeforeNewCycleInterval() throws {
        let t0 = ISO8601DateFormatter().date(from: "2026-07-09T00:00:00Z")!
        let t1h = t0.addingTimeInterval(60 * 60)

        try writer.write { db in
            try StartupBackfills.recordFtsOptimizeAttempt(db, now: t0)
            try db.execute(
                sql: "INSERT INTO metadata(key, value) VALUES (?, '1')",
                arguments: [StartupBackfills.ftsMergeInProgressKey]
            )

            XCTAssertTrue(
                try StartupBackfills.isFtsOptimizeDue(db, now: t1h),
                "a bounded merge already in progress must advance on the next periodic tick"
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

    // EMB-001: semantic_chunks must be a cheap reconciliation signal even after
    // the one-time FTS sweep has already completed.
    func testReconcileSkipTierPurgesJoblessSemanticChunks_repro() throws {
        try writer.write { db in
            try insertSession(db, id: "skip-semantic", source: "codex", tier: "skip")
            try insertSession(db, id: "keep-semantic", source: "codex", tier: "normal")
            try insertSemanticChunk(db, sessionId: "skip-semantic", text: "stale semantic")
            try insertSemanticChunk(db, sessionId: "keep-semantic", text: "kept semantic")
            try db.execute(
                sql: "INSERT INTO metadata(key, value) VALUES (?, ?)",
                arguments: [
                    StartupBackfills.skipTierArtifactReconcileMetadataKey,
                    StartupBackfills.skipTierArtifactReconcileVersion,
                ]
            )

            let removed = try StartupBackfills.reconcileSkipTierIndexArtifacts(db)

            XCTAssertEqual(removed, 1)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_chunks WHERE session_id = 'skip-semantic'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM semantic_chunks WHERE session_id = 'keep-semantic'"),
                1
            )
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
        suggestedParentId: String? = nil,
        parentSessionId: String? = nil,
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
              suggestion_status, suggestion_candidates, suggested_parent_id, parent_session_id,
              model, user_message_count, assistant_message_count, tool_message_count, system_message_count,
              quality_score
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                id, source, startTime, endTime, cwd, project, summary, filePath,
                sourceLocator, agentRole, tier, linkSource, linkCheckedAt,
                suggestionStatus, suggestionCandidates, suggestedParentId, parentSessionId, model,
                userMessageCount, assistantMessageCount, toolMessageCount, systemMessageCount,
                qualityScore
            ]
        )
    }

    private func writeCodexSpawnRollout(
        id: String,
        parentThreadId: String?,
        depth: Int? = 1,
        shape: CodexSpawnShape = .threadSpawn,
        padLine1Past: Int? = nil,
        padFilePast: Int? = nil
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-spawn-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("rollout-\(id).jsonl")

        var sourcePayload: Any
        switch shape {
        case .threadSpawn:
            var spawn: [String: Any] = [:]
            if let parentThreadId {
                spawn["parent_thread_id"] = parentThreadId
            } else {
                spawn["parent_thread_id"] = NSNull()
            }
            if let depth { spawn["depth"] = depth }
            spawn["agent_nickname"] = "Test"
            sourcePayload = ["subagent": ["thread_spawn": spawn]]
        case .reviewWithParent:
            sourcePayload = ["subagent": "review"]
        }

        var payload: [String: Any] = [
            "id": id,
            "source": sourcePayload,
        ]
        if shape == .reviewWithParent, let parentThreadId {
            payload["parent_thread_id"] = parentThreadId
        }
        if shape == .threadSpawn, parentThreadId != nil {
            // Also stamp top-level when present (corpus agreement).
            payload["parent_thread_id"] = parentThreadId as Any
        }

        var lineObject: [String: Any] = [
            "type": "session_meta",
            "payload": payload,
        ]
        if let padLine1Past {
            // Inflate base_instructions so line 1 exceeds the pad threshold.
            lineObject["payload"] = {
                var p = payload
                p["base_instructions"] = String(repeating: "x", count: padLine1Past)
                return p
            }()
        }

        let lineData = try JSONSerialization.data(withJSONObject: lineObject, options: [])
        var body = lineData
        body.append(contentsOf: [0x0A])
        if let padFilePast {
            // Pad so a multi-byte UTF-8 sequence *starts* at `padFilePast` and
            // straddles the 256 KiB head cut (262_144). Example: padFilePast =
            // 262_142 + 3-byte U+2713 (E2 9C 93) → window holds E2 9C only;
            // whole-head UTF-8 decode fails, first-line decode still succeeds.
            let padNeeded = max(0, padFilePast - body.count)
            body.append(contentsOf: Array(repeating: UInt8(0x41), count: padNeeded))
            body.append(contentsOf: [0xE2, 0x9C, 0x93]) // ✓ U+2713, 3 bytes
        }
        try body.write(to: url)
        return url
    }

    private enum CodexSpawnShape {
        case threadSpawn
        case reviewWithParent
    }

    // docs/codex-native-parentage-design-2026-07.md — mirror row 22.
    func testBackfillCodexNativeParentsLinksVendorStampedChild_repro() throws {
        let parentId = "019cb312-98af-7be2-8524-a8c90a1a2b16"
        let childId = "019cb6c7-d7da-7d81-97a7-f2deb2c20a8a"
        let wrongSuggestion = "claude-wrong-parent"
        let rollout = try writeCodexSpawnRollout(id: childId, parentThreadId: parentId)
        defer { try? FileManager.default.removeItem(at: rollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        try writer.write { db in
            try insertSession(db, id: parentId, source: "codex", filePath: "/tmp/.codex/parent.jsonl", tier: "premium")
            try insertSession(
                db,
                id: childId,
                source: "codex",
                filePath: rollout.path,
                agentRole: nil,
                tier: "premium",
                linkCheckedAt: "2026-07-01T00:00:00.000Z",
                suggestedParentId: wrongSuggestion
            )

            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [childId]))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = ?", arguments: [childId]),
                wrongSuggestion
            )

            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 1)

            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [childId]),
                parentId
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = ?", arguments: [childId]), "path")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = ?", arguments: [childId]))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = ?", arguments: [childId]), "dispatched")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = ?", arguments: [childId]), "skip")
        }
    }

    func testBackfillCodexNativeParentsSkipsDepthTwoChains() throws {
        let parentId = "depth2-parent"
        let childId = "depth2-child"
        let rollout = try writeCodexSpawnRollout(id: childId, parentThreadId: parentId, depth: 2)
        defer { try? FileManager.default.removeItem(at: rollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        try writer.write { db in
            try insertSession(db, id: parentId, source: "codex", filePath: "/tmp/.codex/parent.jsonl", tier: "premium")
            try insertSession(db, id: childId, source: "codex", filePath: rollout.path, tier: "premium")
            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 0)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [childId]))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = ?", arguments: [childId]), "premium")
        }
    }

    func testBackfillCodexNativeParentsSkipsSkipTierParents() throws {
        let parentId = "skip-parent"
        let childId = "skip-parent-child"
        let wrong = "wrong-suggestion"
        let rollout = try writeCodexSpawnRollout(id: childId, parentThreadId: parentId)
        defer { try? FileManager.default.removeItem(at: rollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        try writer.write { db in
            try insertSession(db, id: parentId, source: "codex", filePath: "/tmp/.codex/parent.jsonl", tier: "skip")
            try insertSession(
                db,
                id: childId,
                source: "codex",
                filePath: rollout.path,
                tier: "premium",
                suggestedParentId: wrong
            )
            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 0)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [childId]))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = ?", arguments: [childId]),
                wrong
            )
        }
    }

    func testBackfillCodexNativeParentsPreservesManualUnlink() throws {
        let parentId = "manual-parent"
        let childId = "manual-child"
        let rollout = try writeCodexSpawnRollout(id: childId, parentThreadId: parentId)
        defer { try? FileManager.default.removeItem(at: rollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        try writer.write { db in
            try insertSession(db, id: parentId, source: "codex", filePath: "/tmp/.codex/parent.jsonl", tier: "premium")
            try insertSession(
                db,
                id: childId,
                source: "codex",
                filePath: rollout.path,
                linkSource: "manual",
                parentSessionId: nil
            )
            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 0)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [childId]))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = ?", arguments: [childId]), "manual")
        }
    }

    func testBackfillCodexNativeParentsClearsOnlyLinkedRowsSuggestions() throws {
        let parentId = "clear-parent"
        let linkedId = "clear-linked"
        let untouchedId = "clear-untouched"
        let rollout = try writeCodexSpawnRollout(id: linkedId, parentThreadId: parentId)
        defer { try? FileManager.default.removeItem(at: rollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        try writer.write { db in
            try insertSession(db, id: parentId, source: "codex", filePath: "/tmp/.codex/parent.jsonl", tier: "premium")
            try insertSession(
                db,
                id: linkedId,
                source: "codex",
                filePath: rollout.path,
                suggestedParentId: "wrong-a"
            )
            try insertSession(
                db,
                id: untouchedId,
                source: "codex",
                filePath: "/tmp/.codex/no-spawn.jsonl",
                suggestedParentId: "wrong-b"
            )
            // no-spawn file does not exist → not linked
            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 1)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = ?", arguments: [linkedId]))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = ?", arguments: [untouchedId]),
                "wrong-b"
            )
        }
    }

    func testBackfillCodexNativeParentsUsesTopLevelParentThreadIdFallback() throws {
        let parentId = "review-parent"
        let childId = "review-child"
        let rollout = try writeCodexSpawnRollout(id: childId, parentThreadId: parentId, shape: .reviewWithParent)
        defer { try? FileManager.default.removeItem(at: rollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        try writer.write { db in
            try insertSession(db, id: parentId, source: "codex", filePath: "/tmp/.codex/parent.jsonl", tier: "premium")
            try insertSession(db, id: childId, source: "codex", filePath: rollout.path, agentRole: "explorer", tier: "skip")
            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [childId]),
                parentId
            )
            // Existing role preserved.
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT agent_role FROM sessions WHERE id = ?", arguments: [childId]), "explorer")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = ?", arguments: [childId]), "skip")
        }
    }

    func testBackfillCodexNativeParentsReadsLineOneBeyond16KiB() throws {
        let parentId = "pad-parent"
        let childId = "pad-child"
        let rollout = try writeCodexSpawnRollout(id: childId, parentThreadId: parentId, padLine1Past: 20_000)
        defer { try? FileManager.default.removeItem(at: rollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        try writer.write { db in
            try insertSession(db, id: parentId, source: "codex", filePath: "/tmp/.codex/parent.jsonl", tier: "premium")
            try insertSession(db, id: childId, source: "codex", filePath: rollout.path, tier: "premium")
            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [childId]),
                parentId
            )
        }
    }

    /// Multi-byte UTF-8 straddling the 256 KiB head cut: whole-head decode fails;
    /// `readFirstLineBytes` still decodes line 1 and links the child.
    func testBackfillCodexNativeParentsDecodesLineOneAcrossMultiByteHeadBoundary() throws {
        let parentId = "mb-parent"
        let childId = "mb-child"
        let headScan = 256 * 1024 // StartupBackfills.codexModelHeadScanBytes
        // 3-byte U+2713 starts at 262_142 → bytes 262_142..262_144 straddle the cut.
        let multiByteStart = headScan - 2
        let rollout = try writeCodexSpawnRollout(
            id: childId,
            parentThreadId: parentId,
            padFilePast: multiByteStart
        )
        defer { try? FileManager.default.removeItem(at: rollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        // Prove the fixture actually straddles: whole-head UTF-8 fails, first line succeeds.
        let headData = try Data(contentsOf: rollout).prefix(headScan)
        XCTAssertEqual(headData.count, headScan)
        XCTAssertNil(
            String(data: Data(headData), encoding: .utf8),
            "fixture must place a truncated multi-byte sequence at the head cut"
        )
        let firstLine = StartupBackfills.readFirstLineBytes(path: rollout.path, maxBytes: headScan)
        XCTAssertNotNil(firstLine, "first-line decode must survive the straddling multi-byte tail")
        XCTAssertTrue(firstLine?.contains(parentId) == true, firstLine ?? "")

        try writer.write { db in
            try insertSession(db, id: parentId, source: "codex", filePath: "/tmp/.codex/parent.jsonl", tier: "premium")
            try insertSession(db, id: childId, source: "codex", filePath: rollout.path, tier: "premium")
            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [childId]),
                parentId
            )
        }
    }

    /// >500 fully rejected candidates must not strand a later valid child
    /// (guards against LIMIT-500 loops that never advance past rejects).
    func testBackfillCodexNativeParentsDrainsPastAFullyRejectedFirstPage() throws {
        let parentId = "drain-parent"
        let goodChildId = "drain-good-child"
        let goodRollout = try writeCodexSpawnRollout(id: goodChildId, parentThreadId: parentId)
        var rejectRoots: [URL] = []
        defer {
            try? FileManager.default.removeItem(at: goodRollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
            for root in rejectRoots {
                try? FileManager.default.removeItem(at: root)
            }
        }

        try writer.write { db in
            try insertSession(db, id: parentId, source: "codex", filePath: "/tmp/.codex/parent.jsonl", tier: "premium")
            for i in 0..<501 {
                let rejectId = String(format: "drain-reject-%03d", i)
                // depth=2 is always declined; parent exists so path is not the failure mode.
                let rollout = try writeCodexSpawnRollout(id: rejectId, parentThreadId: parentId, depth: 2)
                rejectRoots.append(
                    rollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                )
                try insertSession(db, id: rejectId, source: "codex", filePath: rollout.path, tier: "premium")
            }
            try insertSession(db, id: goodChildId, source: "codex", filePath: goodRollout.path, tier: "premium")

            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [goodChildId]),
                parentId
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: ["drain-reject-000"])
            )
        }
    }

    func testBackfillCodexNativeParentsUsesSourceLocator_repro() throws {
        let parentId = "locator-parent"
        let childId = "locator-child"
        let rollout = try writeCodexSpawnRollout(id: childId, parentThreadId: parentId)
        defer {
            try? FileManager.default.removeItem(
                at: rollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            )
        }

        try writer.write { db in
            try insertSession(db, id: parentId, source: "codex", filePath: "/tmp/.codex/parent.jsonl", tier: "premium")
            try insertSession(
                db,
                id: childId,
                source: "codex",
                filePath: "/tmp/codex-fallback.jsonl",
                sourceLocator: rollout.path,
                tier: "premium"
            )

            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [childId]),
                parentId
            )
        }
    }

    func testBackfillCodexNativeParentsRetriesTransientlyUnresolvedRows_repro() throws {
        let missingParentId = "late-parent"
        let unreadableParentId = "unreadable-parent"
        let missingParentChildId = "missing-parent-child"
        let unreadableChildId = "unreadable-child"
        let missingParentRollout = try writeCodexSpawnRollout(
            id: missingParentChildId,
            parentThreadId: missingParentId
        )
        let unreadableRollout = try writeCodexSpawnRollout(
            id: unreadableChildId,
            parentThreadId: unreadableParentId
        )
        let unreadableData = try Data(contentsOf: unreadableRollout)
        try FileManager.default.removeItem(at: unreadableRollout)
        defer {
            for rollout in [missingParentRollout, unreadableRollout] {
                try? FileManager.default.removeItem(
                    at: rollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                )
            }
        }

        try writer.write { db in
            try insertSession(
                db,
                id: missingParentChildId,
                source: "codex",
                filePath: missingParentRollout.path,
                tier: "premium"
            )
            try insertSession(
                db,
                id: unreadableChildId,
                source: "codex",
                filePath: unreadableRollout.path,
                tier: "premium"
            )

            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 0)
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [missingParentChildId])
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [unreadableChildId])
            )

            try insertSession(db, id: missingParentId, source: "codex", filePath: "/tmp/.codex/late-parent.jsonl", tier: "premium")
            try insertSession(db, id: unreadableParentId, source: "codex", filePath: "/tmp/.codex/unreadable-parent.jsonl", tier: "premium")
            try unreadableData.write(to: unreadableRollout)

            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 2)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [missingParentChildId]),
                missingParentId
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [unreadableChildId]),
                unreadableParentId
            )
        }
    }

    /// Rowid high-water cursor: after scanning rejected rows, later calls do not re-read them
    /// even if the on-disk stamp becomes linkable.
    func testBackfillCodexNativeParentsDoesNotRereadRejectedRowsOnThirdCall() throws {
        let parentId = "cursor-parent"
        let childId = "cursor-reject-then-valid"
        // First pass: depth=2 → rejected but still eligible by SQL (parent null).
        let rejectRollout = try writeCodexSpawnRollout(id: childId, parentThreadId: parentId, depth: 2)
        let root = rejectRollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        try writer.write { db in
            try insertSession(db, id: parentId, source: "codex", filePath: "/tmp/.codex/parent.jsonl", tier: "premium")
            try insertSession(db, id: childId, source: "codex", filePath: rejectRollout.path, tier: "premium")
            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 0)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [childId]))
        }

        // On disk the stamp is now depth=1 and would link if re-read.
        let validRollout = try writeCodexSpawnRollout(id: childId, parentThreadId: parentId, depth: 1)
        defer { try? FileManager.default.removeItem(at: validRollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: rejectRollout)
        try FileManager.default.copyItem(at: validRollout, to: rejectRollout)

        try writer.write { db in
            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 0)
            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 0)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [childId]))
        }
    }

    func testBackfillCodexNativeParentsDeletesFtsRowsWhenTierBecomesSkip() throws {
        let parentId = "fts-parent"
        let childId = "fts-child"
        let rollout = try writeCodexSpawnRollout(id: childId, parentThreadId: parentId)
        defer { try? FileManager.default.removeItem(at: rollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        try writer.write { db in
            try insertSession(db, id: parentId, source: "codex", filePath: "/tmp/.codex/parent.jsonl", tier: "premium")
            try insertSession(db, id: childId, source: "codex", filePath: rollout.path, agentRole: nil, tier: "premium")
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, 'child content')", arguments: [childId])
            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = ?", arguments: [childId]), 0)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT tier FROM sessions WHERE id = ?", arguments: [childId]), "skip")
        }
    }

    func testBackfillCodexNativeParentsVersionGatePreventsSecondSweep() throws {
        let parentId = "vg-parent"
        let childId = "vg-child"
        let rollout = try writeCodexSpawnRollout(id: childId, parentThreadId: parentId)
        let root = rollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        try writer.write { db in
            try insertSession(db, id: parentId, source: "codex", filePath: "/tmp/.codex/parent.jsonl", tier: "premium")
            try insertSession(db, id: childId, source: "codex", filePath: rollout.path, tier: "premium")
            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 1)
        }
        try? FileManager.default.removeItem(at: rollout)
        try writer.write { db in
            // Unlink so a re-read would re-link if it still read the file.
            try db.execute(sql: "UPDATE sessions SET parent_session_id = NULL, link_source = NULL WHERE id = ?", arguments: [childId])
            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 0)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [childId]))
        }
    }

    func testBackfillCodexNativeParentsIsIdempotentOverAlreadyLinkedRows() throws {
        let parentId = "idemp-parent"
        let childId = "idemp-child"
        let rollout = try writeCodexSpawnRollout(id: childId, parentThreadId: parentId)
        defer { try? FileManager.default.removeItem(at: rollout.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        try writer.write { db in
            try insertSession(db, id: parentId, source: "codex", filePath: "/tmp/.codex/parent.jsonl", tier: "premium")
            try insertSession(
                db,
                id: childId,
                source: "codex",
                filePath: rollout.path,
                linkSource: "path",
                parentSessionId: parentId
            )
            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 0)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [childId]),
                parentId
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT link_source FROM sessions WHERE id = ?", arguments: [childId]), "path")
        }
    }

    func testBackfillCodexNativeParentsIgnoresClaudeOpenAIPaths() throws {
        let parentId = "coai-parent"
        let childId = "coai-child"
        // Path deliberately lacks `/.codex/`.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-openai-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(".claude-openai/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let url = root.appendingPathComponent("rollout.jsonl")
        let spawn = try writeCodexSpawnRollout(id: childId, parentThreadId: parentId)
        try FileManager.default.copyItem(at: spawn, to: url)
        try? FileManager.default.removeItem(at: spawn.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())

        try writer.write { db in
            try insertSession(db, id: parentId, source: "codex", filePath: "/tmp/.codex/parent.jsonl", tier: "premium")
            try insertSession(db, id: childId, source: "codex", filePath: url.path, tier: "premium")
            XCTAssertEqual(try StartupBackfills.backfillCodexNativeParents(db), 0)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = ?", arguments: [childId]))
        }
    }

    func testCodexSpawnParentParserShapes() {
        // Shape 1: thread_spawn
        let shape1 = """
        {"type":"session_meta","payload":{"id":"c1","source":{"subagent":{"thread_spawn":{"parent_thread_id":"p1","depth":1}}},"agent_role":"explorer"}}
        """
        let r1 = StartupBackfills.codexSpawnParent(head: shape1)
        XCTAssertEqual(r1?.parentId, "p1")
        XCTAssertEqual(r1?.depth, 1)

        // Shape 3: review + top-level parent_thread_id
        let shape3 = """
        {"type":"session_meta","payload":{"id":"c3","source":{"subagent":"review"},"parent_thread_id":"p3"}}
        """
        XCTAssertEqual(StartupBackfills.codexSpawnParent(head: shape3)?.parentId, "p3")

        // Shape 4: review, no parent
        let shape4 = """
        {"type":"session_meta","payload":{"id":"c4","source":{"subagent":"review"}}}
        """
        XCTAssertNil(StartupBackfills.codexSpawnParent(head: shape4))

        // Bare-string source
        let bare = """
        {"type":"session_meta","payload":{"id":"c5","source":"cli"}}
        """
        XCTAssertNil(StartupBackfills.codexSpawnParent(head: bare))

        // Null parent_thread_id inside thread_spawn
        let nullParent = """
        {"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{"parent_thread_id":null,"depth":1}}}}}
        """
        XCTAssertNil(StartupBackfills.codexSpawnParent(head: nullParent))

        // Depth 2
        let depth2 = """
        {"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{"parent_thread_id":"p2","depth":2}}}}}
        """
        XCTAssertEqual(StartupBackfills.codexSpawnParent(head: depth2)?.depth, 2)

        // Unconditional type gate: bare payload / missing session_meta → nil
        let barePayload = """
        {"id":"c-bare","parent_thread_id":"p-bare","source":{"subagent":{"thread_spawn":{"parent_thread_id":"p-bare","depth":1}}}}
        """
        XCTAssertNil(StartupBackfills.codexSpawnParent(head: barePayload))

        let wrongType = """
        {"type":"event_msg","payload":{"parent_thread_id":"p-wrong","source":{"subagent":{"thread_spawn":{"parent_thread_id":"p-wrong","depth":1}}}}}
        """
        XCTAssertNil(StartupBackfills.codexSpawnParent(head: wrongType))

        let payloadOnlyNoType = """
        {"payload":{"parent_thread_id":"p-not","source":{"subagent":{"thread_spawn":{"parent_thread_id":"p-not","depth":1}}}}}
        """
        XCTAssertNil(StartupBackfills.codexSpawnParent(head: payloadOnlyNoType))
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

    private func insertSemanticChunk(_ db: Database, sessionId: String, text: String) throws {
        try db.execute(
            sql: """
            INSERT INTO semantic_chunks(id, session_id, chunk_index, text, embedding, model, dim)
            VALUES (?, ?, 0, ?, X'00', 'test-model', 1)
            """,
            arguments: ["\(sessionId):0", sessionId, text]
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
    private(set) var probedLocators: [String] = []

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
        probedLocators.append(locator)
        return accessibleLocators.contains(locator)
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

    func backfillCodexNativeParents() throws -> Int {
        callOrder.append("backfillCodexNativeParents")
        return 42
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
        return StartupBackfills.ProviderParentResult(checked: 26, classified: 27, suggested: 29)
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
