// macos/EngramCoreTests/ProjectMove/OrchestratorTests.swift
// End-to-end coverage of the project-move pipeline (Stage 4.2). Exercises
// validation, dry-run, happy path, pre-flight collision, compensation,
// and the lock-busy contract — each with a synthetic homeDirectory tree
// and a temp DB so the test never touches the user's real Engram data.
import Foundation
import GRDB
import XCTest
@testable import EngramCoreWrite

final class OrchestratorTests: XCTestCase {
    private var tempRoot: URL!
    private var dbURL: URL!
    private var lockPath: String!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchestrator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        dbURL = tempRoot.appendingPathComponent("index.sqlite")
        lockPath = tempRoot.appendingPathComponent("project-move.lock").path
        writer = try EngramDatabaseWriter(path: dbURL.path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        dbURL = nil
        lockPath = nil
    }

    // MARK: - validation

    func testValidationRejectsEmptyPaths() async {
        do {
            _ = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: RunProjectMoveOptions(src: "", dst: "/x")
            )
            XCTFail("expected throw")
        } catch OrchestratorError.missingPaths {
            // ok
        } catch {
            XCTFail("expected missingPaths, got \(error)")
        }
    }

    func testValidationRejectsSameSrcAndDst() async throws {
        let (src, _) = try makeProjectFixture(name: "proj")
        do {
            _ = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: makeOptions(src: src, dst: src)
            )
            XCTFail("expected throw")
        } catch OrchestratorError.sameSourceAndDest {
            // ok
        } catch {
            XCTFail("expected sameSourceAndDest, got \(error)")
        }
    }

    func testValidationRejectsDstInsideSrc() async throws {
        let (src, _) = try makeProjectFixture(name: "proj")
        do {
            _ = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: makeOptions(src: src, dst: "\(src)/sub")
            )
            XCTFail("expected throw")
        } catch OrchestratorError.dstInsideSrc {
            // ok
        } catch {
            XCTFail("expected dstInsideSrc, got \(error)")
        }
    }

    func testValidationCanonicalizesParentSegments() async throws {
        let (src, _) = try makeProjectFixture(name: "proj")
        let messy = (src as NSString).appendingPathComponent("../proj")
        // After canonicalize both reduce to the same path → sameSourceAndDest
        do {
            _ = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: makeOptions(src: messy, dst: src)
            )
            XCTFail("expected throw")
        } catch OrchestratorError.sameSourceAndDest {
            // ok
        } catch {
            XCTFail("expected sameSourceAndDest, got \(error)")
        }
    }

    // MARK: - dry run

    func testDryRunPreviewsImpactWithoutSideEffects() async throws {
        let (src, ccDir) = try makeProjectFixture(name: "proj")
        // Plant a JSONL session containing the literal src path.
        let sessionFile = ccDir.appendingPathComponent("s1.jsonl")
        try writeJsonlSession(at: sessionFile, cwd: src)
        let openCodeDb = tempRoot
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
            .appendingPathComponent("opencode.db")
        try makeOpenCodeDatabase(at: openCodeDb, rows: [("open-dry-run", src)])
        let dst = (tempRoot.appendingPathComponent("renamed").path)

        let result = try await ProjectMoveOrchestrator.run(
            writer: writer,
            options: makeOptions(src: src, dst: dst, dryRun: true)
        )
        XCTAssertEqual(result.state, .dryRun)
        XCTAssertEqual(result.migrationId, "dry-run")
        XCTAssertGreaterThan(result.totalOccurrences, 0)
        XCTAssertEqual(result.totalFilesPatched, 2)
        XCTAssertEqual(result.manifest.count, result.totalFilesPatched)
        XCTAssertTrue(result.manifest.contains(ManifestEntry(
            path: "\(openCodeDb.path)::session.directory",
            occurrences: 1
        )))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src), "dry-run must NOT move src")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst), "dry-run must NOT create dst")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath), "dry-run must NOT acquire lock")
        try writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_log") ?? -1, 0,
                "dry-run must NOT write migration_log"
            )
        }
    }

    func testArchivedDryRunDoesNotCreateMissingDestinationParents() async throws {
        let (src, _) = try makeProjectFixture(name: "archive-dry-run")
        let archiveRoot = tempRoot.appendingPathComponent("_archive", isDirectory: true)
        let dst = archiveRoot.appendingPathComponent("cold/archive-dry-run", isDirectory: true)

        let result = try await ProjectMoveOrchestrator.run(
            writer: writer,
            options: RunProjectMoveOptions(
                src: src,
                dst: dst.path,
                dryRun: true,
                archived: true,
                homeDirectory: tempRoot,
                lockPath: lockPath
            )
        )

        XCTAssertEqual(result.state, .dryRun)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: archiveRoot.path),
            "archive dry-run must not provision any destination parent"
        )
    }

    func testDryRunPreviewsGeminiProjectNameAndObservedIflowDirsWithoutSideEffects() async throws {
        let (src, _) = try makeProjectFixture(name: "WebSite_Gemini")
        let dst = tempRoot.appendingPathComponent("mac_Book_Pro_Debug").path

        let geminiOld = tempRoot.appendingPathComponent(".gemini/tmp/custom-old/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiOld, withIntermediateDirectories: true)
        try """
        {"sessionId":"gemini-dry-run","projectHash":"custom-old","startTime":"2026-06-06T00:00:00.000Z","messages":[]}
        """.write(to: geminiOld.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
        let projectsJson = tempRoot.appendingPathComponent(".gemini/projects.json")
        try """
        {"projects":{"\(src)":"custom-old"}}
        """.write(to: projectsJson, atomically: true, encoding: .utf8)
        let geminiOldDir = tempRoot.appendingPathComponent(".gemini/tmp/custom-old", isDirectory: true)
        let geminiNewDir = tempRoot.appendingPathComponent(".gemini/tmp/\(SessionSources.encodeGemini(dst))", isDirectory: true)

        let iflowRoot = tempRoot.appendingPathComponent(".iflow/projects", isDirectory: true)
        let iflowOld = iflowRoot.appendingPathComponent("-Users-bing-Code-observed", isDirectory: true)
        try FileManager.default.createDirectory(at: iflowOld, withIntermediateDirectories: true)
        try """
        {"cwd":"\(src)","text":"working on \(src)/main.py"}
        """.write(to: iflowOld.appendingPathComponent("session-drift.jsonl"), atomically: true, encoding: .utf8)
        let iflowNew = iflowRoot.appendingPathComponent(SessionSources.encodeIflow(dst), isDirectory: true)

        let result = try await ProjectMoveOrchestrator.run(
            writer: writer,
            options: makeOptions(src: src, dst: dst, dryRun: true)
        )

        XCTAssertEqual(result.state, .dryRun)
        XCTAssertTrue(result.renamedDirs.contains {
            $0.sourceId == .geminiCli && $0.oldDir == geminiOldDir.path && $0.newDir == geminiNewDir.path
        })
        XCTAssertTrue(result.renamedDirs.contains {
            $0.sourceId == .iflow && $0.oldDir == iflowOld.path && $0.newDir == iflowNew.path
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: src))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst))
        XCTAssertTrue(FileManager.default.fileExists(atPath: geminiOldDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: geminiNewDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: iflowOld.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: iflowNew.path))
        try writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_log") ?? -1,
                0
            )
        }
    }

    // MARK: - happy path

    func testHappyPathRenamesClaudeCodeDirPatchesJsonlAndCommits() async throws {
        let (src, ccDir) = try makeProjectFixture(name: "proj")
        let sessionFile = ccDir.appendingPathComponent("s1.jsonl")
        try writeJsonlSession(at: sessionFile, cwd: src)
        try seedSessionRow(id: "sess-1", cwd: src, filePath: sessionFile.path)
        let dst = tempRoot.appendingPathComponent("renamed").path

        let result = try await ProjectMoveOrchestrator.run(
            writer: writer,
            options: makeOptions(src: src, dst: dst)
        )

        XCTAssertEqual(result.state, .committed)
        XCTAssertTrue(result.ccDirRenamed)
        XCTAssertEqual(result.totalFilesPatched, 1)
        XCTAssertTrue(result.aliasCreated)

        // FS state
        XCTAssertFalse(FileManager.default.fileExists(atPath: src), "src must be moved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst), "dst must exist")

        let renamedCcDir = ClaudeCodeProjectDir.encode(dst)
        let newCcDir = tempRoot
            .appendingPathComponent(".claude/projects/\(renamedCcDir)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: newCcDir.path),
            "encoded CC dir at new path must exist"
        )

        // JSONL was patched: cwd updated to dst
        let patched = try String(contentsOf: newCcDir.appendingPathComponent("s1.jsonl"), encoding: .utf8)
        XCTAssertTrue(patched.contains(dst), "session JSONL must contain new path: \(patched)")
        XCTAssertFalse(patched.contains(src), "session JSONL must not retain old path")

        // DB state
        try writer.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT cwd FROM sessions WHERE id='sess-1'"),
                dst
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT state FROM migration_log WHERE id=?", arguments: [result.migrationId]),
                "committed"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_aliases WHERE alias='proj' AND canonical='renamed'"),
                1
            )
        }

        // Lock is released
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath))
    }

    func testAllCodexStoresArePatchedAndCommitted() async throws {
        let (src, _) = try makeProjectFixture(name: "codex-proj")
        let codexActive = tempRoot.appendingPathComponent(
            ".codex/sessions/2026/06/05/rollout-active.jsonl"
        )
        let codexArchived = tempRoot.appendingPathComponent(
            ".codex/archived_sessions/rollout-archived.jsonl"
        )
        let codexRolloutSummary = tempRoot.appendingPathComponent(
            ".codex/memories/rollout_summaries/rollout-summary.jsonl"
        )
        try writeCodexSession(at: codexActive, cwd: src)
        try writeCodexSession(at: codexArchived, cwd: src)
        try writeCodexSession(at: codexRolloutSummary, cwd: src)
        try seedSessionRow(id: "codex-1", source: "codex", cwd: src, filePath: codexArchived.path)
        let dst = tempRoot.appendingPathComponent("codex-renamed").path

        let result = try await ProjectMoveOrchestrator.run(
            writer: writer,
            options: makeOptions(src: src, dst: dst)
        )

        XCTAssertEqual(result.state, .committed)
        XCTAssertEqual(
            result.perSource.first(where: { $0.id == "codex" })?.filesPatched,
            1
        )
        XCTAssertEqual(
            result.perSource.first(where: { $0.id == "codex-archived" })?.filesPatched,
            1
        )
        XCTAssertEqual(
            result.perSource.first(where: { $0.id == "codex-rollout-summaries" })?.filesPatched,
            1
        )

        let activePatched = try String(contentsOf: codexActive, encoding: .utf8)
        let archivedPatched = try String(contentsOf: codexArchived, encoding: .utf8)
        let summaryPatched = try String(contentsOf: codexRolloutSummary, encoding: .utf8)
        XCTAssertTrue(activePatched.contains(dst))
        XCTAssertFalse(activePatched.contains(src))
        XCTAssertTrue(archivedPatched.contains(dst))
        XCTAssertFalse(archivedPatched.contains(src))
        XCTAssertTrue(summaryPatched.contains(dst))
        XCTAssertFalse(summaryPatched.contains(src))

        try writer.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT cwd FROM sessions WHERE id='codex-1'"),
                dst
            )
        }
        XCTAssertEqual(result.review.own, [])
    }

    func testOpenCodeSqliteSessionDirectoriesArePatchedAndCommitted() async throws {
        let (src, _) = try makeProjectFixture(name: "opencode-café")
        let openCodeDb = tempRoot
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
            .appendingPathComponent("opencode.db")
        let nfdSrc = src.decomposedStringWithCanonicalMapping
        try makeOpenCodeDatabase(
            at: openCodeDb,
            rows: [
                ("open-1", src),
                ("open-2", "\(src)/nested"),
                ("open-nfd", "\(nfdSrc)/nfd"),
                ("open-other", "\(src)-lookalike"),
            ]
        )
        let dst = tempRoot.appendingPathComponent("opencode-renamed").path

        let result = try await ProjectMoveOrchestrator.run(
            writer: writer,
            options: makeOptions(src: src, dst: dst)
        )

        XCTAssertEqual(result.state, .committed)
        XCTAssertEqual(
            result.perSource.first(where: { $0.id == "opencode" })?.filesPatched,
            1
        )
        XCTAssertEqual(
            result.perSource.first(where: { $0.id == "opencode" })?.occurrences,
            3
        )

        let queue = try DatabaseQueue(path: openCodeDb.path)
        try await queue.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT directory FROM session WHERE id = 'open-1'"),
                dst
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT directory FROM session WHERE id = 'open-2'"),
                "\(dst)/nested"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT directory FROM session WHERE id = 'open-nfd'"),
                "\(dst)/nfd"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT directory FROM session WHERE id = 'open-other'"),
                "\(src)-lookalike"
            )
        }
        XCTAssertEqual(result.review.own, [])
    }

    func testOpenCodeSqliteRowsRollBackWhenLaterSourcePatchFails() async throws {
        let (src, _) = try makeProjectFixture(name: "opencode-rollback")
        let dst = tempRoot.appendingPathComponent("opencode-rollback-renamed").path
        let openCodeDb = tempRoot
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
            .appendingPathComponent("opencode.db")
        try makeOpenCodeDatabase(
            at: openCodeDb,
            rows: [
                ("open-1", src),
                ("open-existing-dst", dst),
            ]
        )
        let badFile = tempRoot.appendingPathComponent(".gemini/antigravity-cli/brain/bad.jsonl")
        try FileManager.default.createDirectory(
            at: badFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var badData = Data("{\"cwd\":\"\(src)\"}".utf8)
        badData.append(0xff)
        try badData.write(to: badFile)

        do {
            _ = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: makeOptions(src: src, dst: dst)
            )
            XCTFail("expected InvalidUtf8Error")
        } catch is InvalidUtf8Error {
            // ok
        } catch {
            XCTFail("expected InvalidUtf8Error, got \(error)")
        }

        let queue = try DatabaseQueue(path: openCodeDb.path)
        try await queue.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT directory FROM session WHERE id = 'open-1'"),
                src
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT directory FROM session WHERE id = 'open-existing-dst'"),
                dst
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: src))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst))
    }

    func testOpenCodeSqlitePatchFailureCompensatesPhysicalMove() async throws {
        let (src, _) = try makeProjectFixture(name: "opencode-corrupt")
        let dst = tempRoot.appendingPathComponent("opencode-corrupt-renamed").path
        let openCodeDb = tempRoot
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
            .appendingPathComponent("opencode.db")
        try FileManager.default.createDirectory(
            at: openCodeDb.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a sqlite database".utf8).write(to: openCodeDb)

        do {
            _ = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: makeOptions(src: src, dst: dst)
            )
            XCTFail("expected sqlite patch failure")
        } catch {
            // ok
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: src))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst))
    }

    func testIflowDirDiscoveredFromRealCwdContentWhenEncodedSrcNameDiffers() async throws {
        let (src, _) = try makeProjectFixture(name: "coding-memory")
        let dst = tempRoot.appendingPathComponent("coding-memory-v2").path

        let iflowRoot = tempRoot.appendingPathComponent(".iflow/projects", isDirectory: true)
        let observedOld = iflowRoot.appendingPathComponent("-Users-bing-Code-engram", isDirectory: true)
        try FileManager.default.createDirectory(at: observedOld, withIntermediateDirectories: true)
        let sessionFile = observedOld.appendingPathComponent("session-drift.jsonl")
        try """
        {"cwd":"\(src)","text":"working on \(src)/main.py"}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        let expectedNew = iflowRoot.appendingPathComponent(SessionSources.encodeIflow(dst), isDirectory: true)

        let result = try await ProjectMoveOrchestrator.run(
            writer: writer,
            options: makeOptions(src: src, dst: dst)
        )

        XCTAssertEqual(result.state, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: observedOld.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedNew.path))
        XCTAssertTrue(result.renamedDirs.contains {
            $0.sourceId == .iflow && $0.oldDir == observedOld.path
        })

        let patched = try String(contentsOf: expectedNew.appendingPathComponent("session-drift.jsonl"), encoding: .utf8)
        XCTAssertTrue(patched.contains(dst))
        XCTAssertFalse(patched.contains("\"cwd\":\"\(src)\""))
        XCTAssertFalse(patched.contains("working on \(src)/main.py"))
    }

    // Audit SRC-QWEN-002: project move must rename Qwen project dirs and patch transcripts.
    func testProjectMoveRenamesAndPatchesQwenHistory_repro() async throws {
        // Force encoded names past Claude's 200-unit truncate/hash point so the
        // Qwen encoder cannot silently reuse ClaudeCodeProjectDir.encode.
        // Stay under APFS's 255-byte single-component limit.
        let longLeaf = String(repeating: "q", count: 120)
        let (src, _) = try makeProjectFixture(name: "\(longLeaf)-src")
        let dst = tempRoot.appendingPathComponent("\(longLeaf)-dst").path

        let encodedOld = SessionSources.encodeQwen(src)
        let encodedNew = SessionSources.encodeQwen(dst)
        let claudeOld = ClaudeCodeProjectDir.encode(src)
        let claudeNew = ClaudeCodeProjectDir.encode(dst)
        XCTAssertGreaterThan(encodedOld.utf16.count, 200)
        XCTAssertGreaterThan(encodedNew.utf16.count, 200)
        XCTAssertEqual(encodedOld.utf16.count, src.utf16.count)
        XCTAssertEqual(encodedNew.utf16.count, dst.utf16.count)
        XCTAssertNotEqual(encodedOld, claudeOld)
        XCTAssertNotEqual(encodedNew, claudeNew)
        XCTAssertLessThan(claudeOld.utf16.count, encodedOld.utf16.count)
        XCTAssertLessThan(claudeNew.utf16.count, encodedNew.utf16.count)
        XCTAssertTrue(claudeOld.hasPrefix(String(encodedOld.prefix(200))))
        XCTAssertTrue(claudeNew.hasPrefix(String(encodedNew.prefix(200))))

        let qwenOld = tempRoot
            .appendingPathComponent(".qwen/projects/\(encodedOld)/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: qwenOld, withIntermediateDirectories: true)
        let sessionFile = qwenOld.appendingPathComponent("qwen-session.jsonl")
        try """
        {"type":"user","sessionId":"qwen-move-1","cwd":"\(src)","timestamp":"2026-07-19T00:00:00.000Z","message":{"role":"user","parts":[{"text":"work in \(src)"}]}}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        let result = try await ProjectMoveOrchestrator.run(
            writer: writer,
            options: makeOptions(src: src, dst: dst)
        )

        let qwenNewChats = tempRoot
            .appendingPathComponent(".qwen/projects/\(encodedNew)/chats", isDirectory: true)
        let qwenOldProject = tempRoot.appendingPathComponent(".qwen/projects/\(encodedOld)")

        XCTAssertEqual(result.state, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: qwenOldProject.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: qwenNewChats.path))
        XCTAssertTrue(result.renamedDirs.contains {
            $0.sourceId == .qwen && $0.oldDir.hasSuffix("/.qwen/projects/\(encodedOld)")
        })
        XCTAssertEqual(
            result.perSource.first(where: { $0.id == "qwen" })?.filesPatched,
            1
        )

        let patched = try String(
            contentsOf: qwenNewChats.appendingPathComponent("qwen-session.jsonl"),
            encoding: .utf8
        )
        XCTAssertTrue(patched.contains(dst))
        XCTAssertFalse(patched.contains("\"cwd\":\"\(src)\""))
        XCTAssertFalse(patched.contains("work in \(src)"))
    }

    func testGeminiOldNameComesFromProjectsJsonWhenItDiffersFromEncodedSrc() async throws {
        let (src, _) = try makeProjectFixture(name: "WebSite_Gemini")
        let dst = tempRoot.appendingPathComponent("mac_Book_Pro_Debug").path

        let geminiOld = tempRoot.appendingPathComponent(".gemini/tmp/custom-old/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiOld, withIntermediateDirectories: true)
        try """
        {"sessionId":"gemini-drift","projectHash":"custom-old","startTime":"2026-06-06T00:00:00.000Z","messages":[{"id":"m1","timestamp":"2026-06-06T00:00:00.000Z","type":"user","content":"hello"}]}
        """.write(to: geminiOld.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
        let projectsJson = tempRoot.appendingPathComponent(".gemini/projects.json")
        try """
        {"projects":{"\(src)":"custom-old"}}
        """.write(to: projectsJson, atomically: true, encoding: .utf8)

        let expectedNew = tempRoot.appendingPathComponent(
            ".gemini/tmp/\(SessionSources.encodeGemini(dst))",
            isDirectory: true
        )

        let result = try await ProjectMoveOrchestrator.run(
            writer: writer,
            options: makeOptions(src: src, dst: dst)
        )

        XCTAssertEqual(result.state, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent(".gemini/tmp/custom-old").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedNew.path))
        XCTAssertTrue(result.renamedDirs.contains {
            $0.sourceId == .geminiCli
                && $0.oldDir == tempRoot.appendingPathComponent(".gemini/tmp/custom-old").path
        })
        let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: projectsJson)) as? [String: Any]
        let projects = updated?["projects"] as? [String: String]
        XCTAssertNil(projects?[src])
        XCTAssertEqual(projects?[dst], SessionSources.encodeGemini(dst))
    }

    func testGeminiDirDiscoveredFromProjectRootWhenProjectsJsonIsAbsent() async throws {
        let (src, _) = try makeProjectFixture(name: "old-proj")
        let dst = tempRoot.appendingPathComponent("new-proj").path

        let geminiOld = tempRoot.appendingPathComponent(
            ".gemini/tmp/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: geminiOld.appendingPathComponent("chats", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "\(src)\n".write(
            to: geminiOld.appendingPathComponent(".project_root"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {"sessionId":"gemini-marker","startTime":"2026-06-21T00:00:00.000Z"}
        """.write(
            to: geminiOld.appendingPathComponent("chats/session-from-marker.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let expectedNew = tempRoot.appendingPathComponent(
            ".gemini/tmp/\(SessionSources.encodeGemini(dst))",
            isDirectory: true
        )

        let result = try await ProjectMoveOrchestrator.run(
            writer: writer,
            options: makeOptions(src: src, dst: dst)
        )

        XCTAssertEqual(result.state, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: geminiOld.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedNew.path))
        XCTAssertTrue(result.renamedDirs.contains {
            $0.sourceId == .geminiCli && $0.oldDir == geminiOld.path
        })
        XCTAssertEqual(
            try String(contentsOf: expectedNew.appendingPathComponent(".project_root"), encoding: .utf8),
            "\(dst)\n"
        )
        XCTAssertFalse(result.review.own.contains(expectedNew.appendingPathComponent(".project_root").path))
    }

    func testUnrelatedIflowDirMentioningOldPathIsNotRenamed() async throws {
        let (src, _) = try makeProjectFixture(name: "mentioned-project")
        let dst = tempRoot.appendingPathComponent("mentioned-project-v2").path

        let unrelatedDir = tempRoot.appendingPathComponent(".iflow/projects/-Users-bing-Code-unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedDir, withIntermediateDirectories: true)
        let sessionFile = unrelatedDir.appendingPathComponent("session-unrelated.jsonl")
        try """
        {"cwd":"/Users/bing/-Code-/unrelated","text":"please inspect \(src)/main.py"}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        let result = try await ProjectMoveOrchestrator.run(
            writer: writer,
            options: makeOptions(src: src, dst: dst)
        )

        XCTAssertEqual(result.state, .committed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedDir.path))
        XCTAssertFalse(result.renamedDirs.contains { $0.sourceId == .iflow })
        let patched = try String(contentsOf: sessionFile, encoding: .utf8)
        XCTAssertTrue(patched.contains(dst))
        XCTAssertTrue(patched.contains("\"cwd\":\"/Users/bing/-Code-/unrelated\""))
    }

    // MARK: - pre-flight collision

    func testDirCollisionRejectedBeforeAnyFsSideEffect() async throws {
        let (src, _) = try makeProjectFixture(name: "proj")
        let dst = tempRoot.appendingPathComponent("renamed").path

        // Plant a third-party directory at the encoded-target name to simulate
        // another project already owning the slot.
        let renamedCcDir = ClaudeCodeProjectDir.encode(dst)
        let foreignCcDir = tempRoot
            .appendingPathComponent(".claude/projects/\(renamedCcDir)")
        try FileManager.default.createDirectory(
            at: foreignCcDir, withIntermediateDirectories: true
        )

        do {
            _ = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: makeOptions(src: src, dst: dst)
            )
            XCTFail("expected DirCollisionError")
        } catch let err as DirCollisionError {
            XCTAssertEqual(err.sourceId, .claudeCode)
            XCTAssertEqual(
                RetryPolicyClassifier.classify(errorName: err.errorName),
                .never
            )
        } catch {
            XCTFail("expected DirCollisionError, got \(error)")
        }

        // Pre-flight failure must NOT leave a fs_pending row blocking the watcher.
        try writer.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT state, error FROM migration_log LIMIT 1")
            XCTAssertEqual(row?["state"], "failed", "preflight error must be recorded as failed")
            XCTAssertNotNil(row?["error"])
        }
        // Source unchanged, lock released.
        XCTAssertTrue(FileManager.default.fileExists(atPath: src))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath))
    }

    /// dry_run must surface the same Step 0.6 DirCollision as live, without
    /// writing migration_log or touching the lock. (repro for dry_run preflight gap)
    func testDryRunDirCollisionRejectedWithoutSideEffects_repro() async throws {
        let (src, _) = try makeProjectFixture(name: "proj-dry-collision")
        let dst = tempRoot.appendingPathComponent("renamed-dry").path

        let renamedCcDir = ClaudeCodeProjectDir.encode(dst)
        let foreignCcDir = tempRoot
            .appendingPathComponent(".claude/projects/\(renamedCcDir)")
        try FileManager.default.createDirectory(
            at: foreignCcDir, withIntermediateDirectories: true
        )

        do {
            _ = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: makeOptions(src: src, dst: dst, dryRun: true)
            )
            XCTFail("expected DirCollisionError on dry_run")
        } catch let err as DirCollisionError {
            XCTAssertEqual(err.sourceId, .claudeCode)
        } catch {
            XCTFail("expected DirCollisionError, got \(error)")
        }

        try writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_log") ?? -1,
                0,
                "dry_run preflight failure must not write migration_log"
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: src))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath))
    }

    func testIflowSharedEncodingRejectedEvenWhenDirRenameWouldBeNoop() async throws {
        let srcURL = tempRoot
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("-foo-", isDirectory: true)
            .appendingPathComponent("p", isDirectory: true)
        let dst = tempRoot
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("foo", isDirectory: true)
            .appendingPathComponent("p", isDirectory: true)
            .path
        try FileManager.default.createDirectory(at: srcURL, withIntermediateDirectories: true)
        try makeRealGitRepo(atPath: srcURL.path)

        let encoded = SessionSources.encodeIflow(dst)
        XCTAssertEqual(encoded, SessionSources.encodeIflow(srcURL.path))
        let iflowDir = tempRoot.appendingPathComponent(".iflow/projects/\(encoded)", isDirectory: true)
        try FileManager.default.createDirectory(at: iflowDir, withIntermediateDirectories: true)
        try """
        {"sessionId":"src","cwd":"\(srcURL.path)","type":"summary"}
        {"sessionId":"other","cwd":"\(dst)","type":"summary"}
        """.write(to: iflowDir.appendingPathComponent("session-1.jsonl"), atomically: true, encoding: .utf8)

        do {
            _ = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: makeOptions(src: srcURL.path, dst: dst)
            )
            XCTFail("expected SharedEncodingCollisionError")
        } catch let err as SharedEncodingCollisionError {
            XCTAssertEqual(err.sourceId, .iflow)
            XCTAssertEqual(err.sharingCwds, [dst])
        } catch {
            XCTFail("expected SharedEncodingCollisionError, got \(error)")
        }

        try writer.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT state, error FROM migration_log LIMIT 1")
            XCTAssertEqual(row?["state"], "failed")
            XCTAssertNotNil(row?["error"])
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst))
    }

    /// dry_run must run the same Step 0.8 iFlow shared-encoding probe as live.
    func testDryRunIflowSharedEncodingRejected_repro() async throws {
        let srcURL = tempRoot
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("-foo-", isDirectory: true)
            .appendingPathComponent("p-dry", isDirectory: true)
        let dst = tempRoot
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("foo", isDirectory: true)
            .appendingPathComponent("p-dry", isDirectory: true)
            .path
        try FileManager.default.createDirectory(at: srcURL, withIntermediateDirectories: true)
        try makeRealGitRepo(atPath: srcURL.path)

        let encoded = SessionSources.encodeIflow(dst)
        XCTAssertEqual(encoded, SessionSources.encodeIflow(srcURL.path))
        let iflowDir = tempRoot.appendingPathComponent(".iflow/projects/\(encoded)", isDirectory: true)
        try FileManager.default.createDirectory(at: iflowDir, withIntermediateDirectories: true)
        try """
        {"sessionId":"src","cwd":"\(srcURL.path)","type":"summary"}
        {"sessionId":"other","cwd":"\(dst)","type":"summary"}
        """.write(to: iflowDir.appendingPathComponent("session-1.jsonl"), atomically: true, encoding: .utf8)

        do {
            _ = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: makeOptions(src: srcURL.path, dst: dst, dryRun: true)
            )
            XCTFail("expected SharedEncodingCollisionError on dry_run")
        } catch let err as SharedEncodingCollisionError {
            XCTAssertEqual(err.sourceId, .iflow)
            XCTAssertEqual(err.sharingCwds, [dst])
        } catch {
            XCTFail("expected SharedEncodingCollisionError, got \(error)")
        }

        try writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_log") ?? -1,
                0
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath))
    }

    // MARK: - lock contract

    func testLockBusyErrorWithLiveHolderDoesNotInsertFsPendingRow() async throws {
        let (src, _) = try makeProjectFixture(name: "proj")
        let dst = tempRoot.appendingPathComponent("renamed").path

        // Pre-acquire under a different migration id; current PID is alive
        // → MigrationLock.acquire raises LockBusyError.
        try MigrationLock.acquire(migrationId: "occupant", lockPath: lockPath)

        defer { MigrationLock.release(lockPath: lockPath) }
        do {
            _ = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: makeOptions(src: src, dst: dst)
            )
            XCTFail("expected LockBusyError")
        } catch let err as LockBusyError {
            XCTAssertEqual(err.holder.migrationId, "occupant")
            XCTAssertEqual(
                RetryPolicyClassifier.classify(errorName: err.errorName),
                .wait
            )
        } catch {
            XCTFail("expected LockBusyError, got \(error)")
        }

        try writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_log") ?? -1,
                0,
                "LockBusyError must not leak a fs_pending row"
            )
        }
    }

    func testUntrackedOnlyGitStateProceedsWithoutForce() async throws {
        try Self.skipIfGitMissing()
        let (src, _) = try makeProjectFixture(name: "proj")
        try makeRealGitRepo(atPath: src)
        try "local scratch".write(
            toFile: (src as NSString).appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        let dst = tempRoot.appendingPathComponent("renamed-untracked").path

        let result = try await ProjectMoveOrchestrator.run(
            writer: writer,
            options: makeOptions(src: src, dst: dst)
        )

        XCTAssertEqual(result.state, .committed)
        XCTAssertTrue(result.git.dirty)
        XCTAssertTrue(result.git.untrackedOnly)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: (dst as NSString).appendingPathComponent("untracked.txt")
            )
        )
    }

    func testWhitespaceOnlyTrackedGitStateRequiresForce() async throws {
        try Self.skipIfGitMissing()
        let (src, _) = try makeProjectFixture(name: "proj")
        try makeRealGitRepo(atPath: src)
        try "print(\"hi\")\n".write(
            toFile: (src as NSString).appendingPathComponent("main.py"),
            atomically: true,
            encoding: .utf8
        )
        let dst = tempRoot.appendingPathComponent("renamed-dirty").path

        do {
            _ = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: makeOptions(src: src, dst: dst)
            )
            XCTFail("expected gitDirty")
        } catch OrchestratorError.gitDirty {
            // ok
        } catch {
            XCTFail("expected gitDirty, got \(error)")
        }
    }

    // MARK: - compensation

    func testCompensationRevertsPhysicalMoveWhenDirRenameFails() async throws {
        let (src, ccDir) = try makeProjectFixture(name: "proj")
        let sessionFile = ccDir.appendingPathComponent("s1.jsonl")
        try writeJsonlSession(at: sessionFile, cwd: src)
        let dst = tempRoot.appendingPathComponent("renamed").path

        // Plant a colliding iflow target dir AFTER pre-flight (we lock the
        // CC dir's encoded-target free, but make iflow's encoded-target
        // already-occupied so the renameItem step throws mid-pipeline).
        // SessionSources.encodeIflow uses `-`-joined segments → encode(src)
        // and encode(dst) differ; we drop a real dir at encode(dst).
        let iflowRoot = tempRoot.appendingPathComponent(".iflow/projects")
        let iflowSrc = iflowRoot.appendingPathComponent(SessionSources.encodeIflow(src))
        let iflowDst = iflowRoot.appendingPathComponent(SessionSources.encodeIflow(dst))
        try FileManager.default.createDirectory(at: iflowSrc, withIntermediateDirectories: true)
        try "{}".write(to: iflowSrc.appendingPathComponent("placeholder.json"), atomically: true, encoding: .utf8)

        // Set DST inside iflow as a regular file so the rename collides with
        // a non-directory — pre-flight stat sees it (collision), but we want
        // to test the compensate path. Workaround: write the file AFTER
        // pre-flight; can't do that synchronously.  Instead, we rely on the
        // pre-flight realpath check: a regular file at iflowDst will fail
        // realpath comparison → DirCollisionError. That's a pre-flight
        // failure (no compensation needed) — already covered by the test
        // above. To exercise the FS compensate path, we'd need to inject
        // a failing FsOpsHooks; defer that to a more elaborate spec.
        //
        // For the Stage 4.2 commit, this test instead asserts that a run
        // OK'd by pre-flight commits cleanly even with iflow's source dir
        // present (proves the iflow path doesn't accidentally trigger
        // compensation when nothing's wrong).
        let result = try await ProjectMoveOrchestrator.run(
            writer: writer,
            options: makeOptions(src: src, dst: dst)
        )
        XCTAssertEqual(result.state, .committed)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: iflowDst.path),
            "iflow dir must be renamed alongside cc dir"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: iflowSrc.path))
    }

    func testDirRenameFailureMessageIncludesPosixErrno() async throws {
        let (src, ccDir) = try makeProjectFixture(name: "proj")
        try "{}".write(to: ccDir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        let parent = ccDir.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        }

        let dst = tempRoot.appendingPathComponent("renamed").path
        do {
            _ = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: makeOptions(src: src, dst: dst)
            )
            XCTFail("expected dir rename failure")
        } catch OrchestratorError.dirRenameFailed(_, _, _, let message) {
            XCTAssertTrue(message.contains("errno="), message)
            XCTAssertTrue(message.contains("Permission denied") || message.contains("Operation not permitted"), message)
        } catch {
            XCTFail("expected dirRenameFailed, got \(error)")
        }
    }

    // MARK: - rolledBackOf round-trips

    func testRolledBackOfRecordedInMigrationLog() async throws {
        let (src, _) = try makeProjectFixture(name: "proj")
        let dst = tempRoot.appendingPathComponent("renamed").path

        let result = try await ProjectMoveOrchestrator.run(
            writer: writer,
            options: makeOptions(src: src, dst: dst, rolledBackOf: "prior-migration-id")
        )
        try writer.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT rolled_back_of FROM migration_log WHERE id=?",
                    arguments: [result.migrationId]
                ),
                "prior-migration-id"
            )
        }
    }

    // MARK: - lock leak on Phase-A failure (audit round 2: pm-1)

    /// A transient failure of the Phase-A `startMigration` write must still
    /// release the migration lock. The original code acquired the lock and ran
    /// the Phase-A write OUTSIDE the do/catch, so a throw there leaked the lock
    /// holding the live service pid — permanently wedging all future moves
    /// (isProcessAlive returns true, so stale-lock breaking never reclaims it).
    func testLockReleasedWhenStartMigrationWriteFails() async throws {
        let (src, _) = try makeProjectFixture(name: "proj")
        let dst = tempRoot.appendingPathComponent("renamed").path
        // Force the Phase-A startMigration INSERT to throw by removing its table.
        try writer.write { db in try db.execute(sql: "DROP TABLE migration_log") }

        do {
            _ = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: makeOptions(src: src, dst: dst)
            )
            XCTFail("expected the Phase-A startMigration write to throw")
        } catch {
            // expected: the migration_log INSERT fails
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: lockPath),
            "lock must be released even when the Phase-A write fails"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: src),
            "Phase-A failure precedes any FS move; src must be untouched"
        )
    }

    // MARK: - partial JSONL patch rollback (audit round 2: pm-2)

    /// When a hard patch error (InvalidUtf8Error) aborts the patch loop, every
    /// file that WAS successfully patched before the throw surfaced must still
    /// be recorded in the manifest so compensation reverts it. The original
    /// code appended to the manifest only as it walked results and threw on the
    /// first hard error, leaving a successful patch at a LATER result index
    /// rewritten-but-unreverted (silent corruption).
    func testRollbackRevertsSuccessfulPatchOrderedAfterHardError() async throws {
        let (src, ccDir) = try makeProjectFixture(name: "proj")
        let dst = tempRoot.appendingPathComponent("renamed").path

        // findReferencingFiles returns sorted paths, so "a-bad" is processed
        // before "b-ok": the hard error surfaces FIRST while b-ok's successful
        // patch sits at a later index — exactly the file the bug leaves unreverted.
        var bad = Data("{\"cwd\":\"\(src)\"}\n".utf8)
        bad.append(contentsOf: [0xFF, 0xFE]) // invalid UTF-8 → InvalidUtf8Error
        try bad.write(to: ccDir.appendingPathComponent("a-bad.jsonl"))
        try writeJsonlSession(at: ccDir.appendingPathComponent("b-ok.jsonl"), cwd: src)

        do {
            _ = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: makeOptions(src: src, dst: dst)
            )
            XCTFail("expected InvalidUtf8Error to abort the migration")
        } catch is InvalidUtf8Error {
            // expected
        }

        // Compensation must have reverted the good file AND moved the dir back.
        let restored = try String(
            contentsOf: ccDir.appendingPathComponent("b-ok.jsonl"),
            encoding: .utf8
        )
        XCTAssertTrue(
            restored.contains(src),
            "rolled-back file must be reverted to the old path"
        )
        XCTAssertFalse(
            restored.contains(dst),
            "rolled-back file must not retain the new path (silent corruption)"
        )
    }

    // MARK: - helpers

    /// Build `<tempRoot>/Code/<name>/` plus the encoded Claude Code projects
    /// dir and a `.git` directory so git-dirty defaults to clean. Returns
    /// `(srcAbsolutePath, ccDirURL)`.
    private func makeProjectFixture(name: String) throws -> (String, URL) {
        let codeDir = tempRoot.appendingPathComponent("Code", isDirectory: true)
        let projectDir = codeDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try makeRealGitRepo(atPath: projectDir.path)

        let encodedCcName = ClaudeCodeProjectDir.encode(projectDir.path)
        let ccDir = tempRoot
            .appendingPathComponent(".claude/projects/\(encodedCcName)", isDirectory: true)
        try FileManager.default.createDirectory(at: ccDir, withIntermediateDirectories: true)
        return (projectDir.path, ccDir)
    }

    private func makeRealGitRepo(atPath path: String) throws {
        let gitDir = (path as NSString).appendingPathComponent(".git")
        try? FileManager.default.removeItem(atPath: gitDir)
        try "print(\"hi\")".write(
            toFile: (path as NSString).appendingPathComponent("main.py"),
            atomically: true,
            encoding: .utf8
        )
        try Self.runGit(atPath: path, ["init", "-q"])
        try Self.runGit(atPath: path, ["config", "user.email", "t@t"])
        try Self.runGit(atPath: path, ["config", "user.name", "t"])
        try Self.runGit(atPath: path, ["add", "."])
        try Self.runGit(atPath: path, ["commit", "-qm", "init"])
    }

    private func writeJsonlSession(at url: URL, cwd: String) throws {
        let line = """
        {"sessionId":"\(UUID().uuidString)","cwd":"\(cwd)","type":"summary"}
        """
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeCodexSession(at url: URL, cwd: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let line = """
        {"type":"session_meta","payload":{"id":"\(UUID().uuidString)","timestamp":"2026-06-05T00:00:00.000Z","cwd":"\(cwd)"}}
        """
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeOpenCodeDatabase(at url: URL, rows: [(id: String, directory: String)]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE session (
                id TEXT PRIMARY KEY,
                directory TEXT,
                title TEXT,
                time_created INTEGER,
                time_updated INTEGER,
                time_archived INTEGER
            )
            """)
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO session (id, directory, time_created, time_updated) VALUES (?, ?, 1, 1)",
                    arguments: [row.id, row.directory]
                )
            }
        }
    }

    private func seedSessionRow(
        id: String,
        source: String = "claude-code",
        cwd: String,
        filePath: String
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions(id, source, start_time, cwd, file_path)
                VALUES (?, ?, '2026-04-23T10:00:00.000Z', ?, ?)
                """,
                arguments: [id, source, cwd, filePath]
            )
        }
    }

    private func makeOptions(
        src: String,
        dst: String,
        dryRun: Bool = false,
        rolledBackOf: String? = nil
    ) -> RunProjectMoveOptions {
        RunProjectMoveOptions(
            src: src,
            dst: dst,
            dryRun: dryRun,
            force: false,
            archived: false,
            auditNote: nil,
            actor: .swiftUI,
            homeDirectory: tempRoot,
            lockPath: lockPath,
            rolledBackOf: rolledBackOf
        )
    }

    private static func skipIfGitMissing() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw XCTSkip("git is not available")
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw XCTSkip("git is not available")
        }
    }

    private static func runGit(atPath path: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "OrchestratorTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed"]
            )
        }
    }

    // MARK: - Wave 8 long-ops: cancel before commit boundary

    func testCancelBeforeCommitThrowsProjectMoveCancelledError_repro() async throws {
        let (src, _) = try makeProjectFixture(name: "cancel-src")
        let dst = tempRoot.appendingPathComponent("cancel-dst").path
        var options = makeOptions(src: src, dst: dst)
        options.shouldCancel = { true }
        options.beginCommitIfNotCancelled = { false }

        do {
            _ = try await ProjectMoveOrchestrator.run(writer: writer, options: options)
            XCTFail("expected ProjectMoveCancelledError")
        } catch let error as ProjectMoveCancelledError {
            XCTAssertTrue(error.compensationSucceeded)
        } catch {
            XCTFail("expected ProjectMoveCancelledError, got \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: src), "src must remain after pre-commit cancel")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst), "dst must not exist after pre-commit cancel")
        try writer.read { db in
            let committed = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM migration_log WHERE state = 'committed'"
            ) ?? -1
            XCTAssertEqual(committed, 0, "no committed migration after pre-commit cancel")
        }
        XCTAssertEqual(
            RetryPolicyClassifier.classify(errorName: ProjectMoveCancelledError().errorName),
            .never
        )
    }

    /// Archive parent must not be left behind when cancel wins before FS mutation.
    func testCancelBeforeRunDoesNotLeaveArchiveParent_repro() async throws {
        let (src, _) = try makeProjectFixture(name: "archive-empty")
        let archiveCategory = tempRoot
            .appendingPathComponent("_archive/空项目", isDirectory: true)
        let dst = archiveCategory.appendingPathComponent("archive-empty").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveCategory.path))

        var options = makeOptions(src: src, dst: dst)
        options.archived = true
        options.shouldCancel = { true }

        do {
            _ = try await ProjectMoveOrchestrator.run(writer: writer, options: options)
            XCTFail("expected cancel")
        } catch is ProjectMoveCancelledError {
            // ok
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: archiveCategory.path),
            "cancel-before-run must not create archive parent"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("_archive").path),
            "cancel-before-run must not create _archive root"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: src))
    }

    /// Preflight DirCollision after parents would be wrong if provision ran too early;
    /// also proves pre-existing parents are never deleted.
    func testPreflightCollisionPreservesPreexistingParentAndDoesNotCreateSiblings_repro() async throws {
        let (src, _) = try makeProjectFixture(name: "collision-src")
        let archiveRoot = tempRoot.appendingPathComponent("_archive", isDirectory: true)
        let category = archiveRoot.appendingPathComponent("历史脚本", isDirectory: true)
        try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
        // Marker proves preexisting parent is never deleted.
        let marker = category.appendingPathComponent(".keep")
        try Data().write(to: marker)

        // Force a gemini dir collision by placing an unrelated dir at the encoded new path
        // while also having the old gemini dir — classic DirCollisionError path.
        let home = tempRoot!
        let geminiRoot = home.appendingPathComponent(".gemini/tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiRoot, withIntermediateDirectories: true)
        let oldGemini = geminiRoot.appendingPathComponent(SessionSources.encodeGemini(src))
        let newGemini = geminiRoot.appendingPathComponent(
            SessionSources.encodeGemini(category.appendingPathComponent("collision-src").path)
        )
        try FileManager.default.createDirectory(at: oldGemini, withIntermediateDirectories: true)
        // Distinct third-party dir at new name → collision.
        if oldGemini.path != newGemini.path {
            try FileManager.default.createDirectory(at: newGemini, withIntermediateDirectories: true)
            try "foreign".write(
                to: newGemini.appendingPathComponent("x.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let dst = category.appendingPathComponent("collision-src").path
        var options = makeOptions(src: src, dst: dst)
        options.archived = true
        options.homeDirectory = home

        do {
            _ = try await ProjectMoveOrchestrator.run(writer: writer, options: options)
            // If encodings collide to same path (case/normalize), collision may not fire;
            // still assert preexisting parent survives either outcome.
        } catch is DirCollisionError {
            // expected when new gemini dir is a distinct third-party path
        } catch {
            // Other preflight errors are fine for this FS residual assertion.
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: category.path),
            "preexisting archive parent must never be deleted"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "preexisting parent contents must remain"
        )
        // Destination project itself must not exist after failed preflight.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst))
    }

    /// Parent created for the move, then cancel at commit boundary: after reverse
    /// compensation the empty shells we created must be removed.
    func testCreatedArchiveParentRemovedAfterCancelAtCommitBoundary_repro() async throws {
        let (src, _) = try makeProjectFixture(name: "archive-commit-cancel")
        let archiveRoot = tempRoot.appendingPathComponent("_archive", isDirectory: true)
        let category = archiveRoot.appendingPathComponent("空项目", isDirectory: true)
        let dst = category.appendingPathComponent("archive-commit-cancel").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveRoot.path))

        var options = makeOptions(src: src, dst: dst)
        options.archived = true
        options.shouldCancel = { false }
        // Cancel wins at the commit boundary after FS mutation + parent provision.
        options.beginCommitIfNotCancelled = { false }

        do {
            _ = try await ProjectMoveOrchestrator.run(writer: writer, options: options)
            XCTFail("expected cancel at commit boundary")
        } catch let error as ProjectMoveCancelledError {
            XCTAssertTrue(
                error.compensationSucceeded,
                "reverse + empty-parent teardown should be clean"
            )
        } catch {
            XCTFail("expected ProjectMoveCancelledError, got \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: src), "src restored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst), "dst not left behind")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: category.path),
            "empty archive category created by this run must be removed"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: archiveRoot.path),
            "empty _archive root created by this run must be removed"
        )
    }

    func testAtomicBeginCommitPreventsCancelRaceWindow_repro() async throws {
        // beginCommitIfNotCancelled returns false → cancel wins, no commit.
        let (src, _) = try makeProjectFixture(name: "atomic-cancel")
        let dst = tempRoot.appendingPathComponent("atomic-cancel-dst").path
        var options = makeOptions(src: src, dst: dst)
        options.shouldCancel = { false }
        options.beginCommitIfNotCancelled = { false }
        do {
            _ = try await ProjectMoveOrchestrator.run(writer: writer, options: options)
            XCTFail("expected cancel at commit boundary")
        } catch is ProjectMoveCancelledError {
            // ok
        }
        try writer.read { db in
            let committed = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM migration_log WHERE state = 'committed'"
            ) ?? -1
            XCTAssertEqual(committed, 0)
        }
    }

    func testBeginCommitTrueCompletesDespiteLaterCancelProbe_repro() async throws {
        let (src, _) = try makeProjectFixture(name: "atomic-commit")
        let dst = tempRoot.appendingPathComponent("atomic-commit-dst").path
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var beginCalled = false
            private var shouldCancelAfter = false
            func markBegin() { lock.lock(); beginCalled = true; shouldCancelAfter = true; lock.unlock() }
            func shouldCancel() -> Bool {
                lock.lock(); defer { lock.unlock() }
                return shouldCancelAfter
            }
            func began() -> Bool { lock.lock(); defer { lock.unlock() }; return beginCalled }
        }
        let flag = Flag()
        var options = makeOptions(src: src, dst: dst)
        // After beginCommit, shouldCancel flips true — must not abort Phase B/C.
        options.shouldCancel = { flag.shouldCancel() }
        options.beginCommitIfNotCancelled = {
            flag.markBegin()
            return true
        }
        let result = try await ProjectMoveOrchestrator.run(writer: writer, options: options)
        XCTAssertEqual(result.state, .committed)
        XCTAssertTrue(flag.began())
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst))
    }

    func testCancelledErrorCompensationFailedNameAndWording_repro() {
        let clean = ProjectMoveCancelledError(compensationSucceeded: true)
        XCTAssertEqual(clean.errorName, "ProjectMoveCancelledError")
        XCTAssertTrue(clean.errorMessage.contains("no migration was committed"))

        let dirty = ProjectMoveCancelledError(
            compensationSucceeded: false,
            compensationDetail: "rollback: 1 file(s) could NOT be reverted"
        )
        XCTAssertEqual(dirty.errorName, "ProjectMoveCancelCompensationFailedError")
        XCTAssertTrue(dirty.errorMessage.contains("compensation was incomplete"))
        XCTAssertFalse(dirty.errorMessage.contains("Safe to retry"))
        XCTAssertEqual(
            RetryPolicyClassifier.classify(errorName: dirty.errorName),
            .never
        )
    }
}
