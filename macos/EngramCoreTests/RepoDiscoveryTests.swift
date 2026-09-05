import Foundation
import GRDB
import XCTest
import Darwin
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class RepoDiscoveryTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-discovery-\(UUID().uuidString).sqlite")
        writer = try EngramDatabaseWriter(path: tempDB.path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let tempDB { try? FileManager.default.removeItem(at: tempDB) }
        tempDB = nil
    }

    // sessionCwdCounts caps the per-cycle git fan-out to the busiest cwds so an
    // unbounded list of one-off cwds can't spawn unbounded git subprocesses.
    func testSessionCwdCountsCapsToBusiestCwds() throws {
        try writer.write { db in
            let rows: [(String, Int)] = [("/a", 3), ("/b", 2), ("/c", 1)]
            var n = 0
            for (cwd, count) in rows {
                for _ in 0..<count {
                    n += 1
                    try db.execute(
                        sql: "INSERT INTO sessions(id, source, start_time, cwd, file_path, instruction_count, human_turn_count) VALUES (?, 'codex', '2026-05-08T09:00:00.000Z', ?, ?, 2, 2)",
                        arguments: ["s\(n)", cwd, "/tmp/s\(n).jsonl"]
                    )
                }
            }
        }

        let top2 = try writer.read { db in try RepoDiscovery.sessionCwdCounts(db, limit: 2) }
        XCTAssertEqual(top2.count, 2, "limit caps the candidate count")
        XCTAssertEqual(Set(top2.map(\.cwd)), ["/a", "/b"], "keeps the busiest cwds, drops the long tail")
    }

    func testSessionCwdCountsMatchesRepoBrowsePopulation_repro() throws {
        try writer.write { db in
            try insertSession(db, id: "human-root", cwd: "/work/r")
            try insertSession(db, id: "confirmed-child", cwd: "/work/r")
            try insertSession(db, id: "single-shot-root", cwd: "/work/r")
            try db.execute(
                sql: "UPDATE sessions SET parent_session_id = 'human-root' WHERE id = 'confirmed-child'"
            )
            try db.execute(
                sql: "UPDATE sessions SET instruction_count = 0, human_turn_count = 1, user_message_count = 1 WHERE id = 'single-shot-root'"
            )

            XCTAssertEqual(
                try RepoDiscovery.sessionCwdCounts(db),
                [GitRepoCandidate(cwd: "/work/r", sessionCount: 1)]
            )
        }
    }

    // Injected-probe path: deterministic field assertions + session_count
    // aggregation across sub-dir cwds that map to one repo top-level.
    func testDiscoverAggregatesSessionsByRepoAndSkipsNonRepos() throws {
        let probes: [String: GitRepoProbe] = [
            "/work/engram": GitRepoProbe(
                path: "/work/engram", name: "engram", branch: "main",
                dirtyCount: 2, untrackedCount: 1, unpushedCount: 3,
                lastCommitHash: "abc123", lastCommitMsg: "feat: add a | b option",
                lastCommitAt: "2026-05-23T10:00:00Z"
            )
        ]
        // Two cwds (root + sub-dir) resolve to the same repo; one is not a repo.
        let probe: (String) -> GitRepoProbe? = { cwd in
            if cwd == "/work/engram" || cwd == "/work/engram/macos" { return probes["/work/engram"] }
            return nil
        }

        try writer.write { db in
            try insertSession(db, id: "s1", cwd: "/work/engram")
            try insertSession(db, id: "s2", cwd: "/work/engram/macos")
            try insertSession(db, id: "s3", cwd: "/tmp/not-a-repo")
            try insertSession(db, id: "s4", cwd: "") // ignored

            let count = try RepoDiscovery.discover(db, probe: probe, now: { "2026-05-23T12:00:00Z" })
            XCTAssertEqual(count, 1)

            let row = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM git_repos"))
            XCTAssertEqual(row["path"] as String?, "/work/engram")
            XCTAssertEqual(row["name"] as String?, "engram")
            XCTAssertEqual(row["branch"] as String?, "main")
            XCTAssertEqual(row["dirty_count"] as Int?, 2)
            XCTAssertEqual(row["untracked_count"] as Int?, 1)
            XCTAssertEqual(row["unpushed_count"] as Int?, 3)
            // The `|` in the commit message must survive (NUL-separated probe).
            XCTAssertEqual(row["last_commit_msg"] as String?, "feat: add a | b option")
            XCTAssertEqual(row["session_count"] as Int?, 2)
            XCTAssertEqual(row["probed_at"] as String?, "2026-05-23T12:00:00Z")
        }
    }

    // Upsert: a second discovery refreshes the row in place, not duplicates.
    func testDiscoverUpsertsExistingRepo() throws {
        var dirty = 0
        let probe: (String) -> GitRepoProbe? = { _ in
            GitRepoProbe(
                path: "/work/r", name: "r", branch: "main",
                dirtyCount: dirty, untrackedCount: 0, unpushedCount: 0,
                lastCommitHash: nil, lastCommitMsg: nil, lastCommitAt: nil
            )
        }
        try writer.write { db in
            try insertSession(db, id: "s1", cwd: "/work/r")
            _ = try RepoDiscovery.discover(db, probe: probe, now: { "t1" })
            dirty = 5
            _ = try RepoDiscovery.discover(db, probe: probe, now: { "t2" })

            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM git_repos"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT dirty_count FROM git_repos WHERE path='/work/r'"), 5)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT probed_at FROM git_repos WHERE path='/work/r'"), "t2")
        }
    }

    // docs/invariants.md invariant 3: repo counts use the full list-visible
    // population, not the throttled metadata-probe batch.
    func testUpsertUsesFullVisibleSessionCountAndPrunesGhostRepos_repro() throws {
        try writer.write { db in
            try insertSession(db, id: "root", cwd: "/work/r")
            try insertSession(db, id: "child-a", cwd: "/work/r/Sources")
            try insertSession(db, id: "child-b", cwd: "/work/r/Tests")
            try insertSession(db, id: "skip", cwd: "/work/r/Hidden")
            try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'skip'")
            try db.execute(
                sql: "INSERT INTO git_repos(path, name, session_count) VALUES ('/work/ghost', 'ghost', 9)"
            )

            let probe = GitRepoProbe(
                path: "/work/r",
                name: "r",
                branch: "main",
                dirtyCount: 0,
                untrackedCount: 0,
                unpushedCount: 0,
                lastCommitHash: nil,
                lastCommitMsg: nil,
                lastCommitAt: nil
            )
            _ = try RepoDiscovery.upsert(
                db,
                entries: [GitRepoDiscoveryEntry(probe: probe, sessionCount: 1)],
                cwdToRepoPath: [
                    "/work/r": "/work/r",
                    "/work/r/Sources": "/work/r",
                    "/work/r/Tests": "/work/r",
                ],
                probedAt: "now"
            )

            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT session_count FROM git_repos WHERE path = '/work/r'"),
                3
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM git_repos WHERE path = '/work/ghost'"),
                0
            )
        }

        let candidates = try writer.read { db in
            try RepoDiscovery.sessionCwdCounts(db)
        }
        XCTAssertFalse(candidates.contains { $0.cwd == "/work/r/Hidden" })
    }

    // docs/invariants.md invariant 3: hidden/skip sessions do not contribute to
    // visible KPIs, but their cwd still keeps repository identity and aliases alive.
    func testRecountPreservesRepoReferencedOnlyByHiddenSkipSession_repro() throws {
        try writer.write { db in
            try insertSession(db, id: "hidden-skip", cwd: "/work/held/subdir")
            try db.execute(
                sql: "UPDATE sessions SET tier = 'skip', hidden_at = '2026-08-23T00:00:00Z' WHERE id = 'hidden-skip'"
            )
            try db.execute(
                sql: "INSERT INTO git_repos(path, name, session_count) VALUES ('/work/held', 'held', 4)"
            )
            try db.execute(
                sql: "INSERT INTO git_repo_cwd_aliases(cwd, real_cwd, repo_path) VALUES ('/work/held/subdir', '/work/held/subdir', '/work/held')"
            )

            try RepoDiscovery.recount(db)

            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM git_repos WHERE path = '/work/held'"),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT session_count FROM git_repos WHERE path = '/work/held'"),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM git_repo_cwd_aliases WHERE repo_path = '/work/held'"),
                1
            )
        }
    }

    func testRepoRecountAvoidsNestedPrefixDoubleCountAndPreservesRealpathAlias_repro() throws {
        let aliasedRepo = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-repo-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: aliasedRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: aliasedRepo) }
        let realRepoPath = aliasedRepo.resolvingSymlinksInPath().path

        try writer.write { db in
            try insertSession(db, id: "work-root", cwd: "/work")
            try insertSession(db, id: "work-nested", cwd: "/work/engram")
            try insertSession(db, id: "tmp-alias", cwd: aliasedRepo.path)
            let probes = [
                GitRepoProbe(
                    path: "/work", name: "work", branch: nil,
                    dirtyCount: 0, untrackedCount: 0, unpushedCount: 0,
                    lastCommitHash: nil, lastCommitMsg: nil, lastCommitAt: nil
                ),
                GitRepoProbe(
                    path: "/work/engram", name: "engram", branch: nil,
                    dirtyCount: 0, untrackedCount: 0, unpushedCount: 0,
                    lastCommitHash: nil, lastCommitMsg: nil, lastCommitAt: nil
                ),
                GitRepoProbe(
                    path: realRepoPath, name: "alias", branch: nil,
                    dirtyCount: 0, untrackedCount: 0, unpushedCount: 0,
                    lastCommitHash: nil, lastCommitMsg: nil, lastCommitAt: nil
                ),
            ]
            _ = try RepoDiscovery.upsert(
                db,
                entries: probes.map { GitRepoDiscoveryEntry(probe: $0, sessionCount: 1) },
                probedAt: "now"
            )

            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT session_count FROM git_repos WHERE path = '/work'"),
                1,
                "a nested repository must not also count toward its path-prefix parent"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT session_count FROM git_repos WHERE path = '/work/engram'"),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT session_count FROM git_repos WHERE path = ?", arguments: [realRepoPath]),
                1,
                "/tmp and /private/tmp spellings must resolve to the same known repo"
            )
        }
    }

    func testRepoRecountPrefersLongestRepoOverStaleShortAlias_repro() throws {
        try writer.write { db in
            try insertSession(db, id: "work-root", cwd: "/work")
            try insertSession(db, id: "work-nested", cwd: "/work/engram")
            try db.execute(sql: """
                INSERT INTO git_repos(path, name, session_count) VALUES
                  ('/work', 'work', 0),
                  ('/work/engram', 'engram', 0);
                INSERT INTO git_repo_cwd_aliases(cwd, real_cwd, repo_path)
                VALUES ('/work/engram', '/work/engram', '/work');
                """)

            try RepoDiscovery.recount(db)

            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT session_count FROM git_repos WHERE path = '/work'"),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT session_count FROM git_repos WHERE path = '/work/engram'"),
                1
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT repo_path FROM git_repo_cwd_aliases WHERE cwd = '/work/engram'"
                ),
                "/work/engram"
            )
        }
    }

    func testRepoRecountKeepsMissingAliasSpellingAssignedToRealRepo_repro() throws {
        let aliasPath = "/tmp/engram-repo-missing-\(UUID().uuidString)/deleted/leaf"
        let realPath = "/private\(aliasPath)"
        try writer.write { db in
            try insertSession(db, id: "missing-alias", cwd: aliasPath)
            try db.execute(
                sql: "INSERT INTO git_repos(path, name, session_count) VALUES (?, 'missing', 0)",
                arguments: [realPath]
            )

            try RepoDiscovery.recount(db)

            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT session_count FROM git_repos WHERE path = ?", arguments: [realPath]),
                1
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT real_cwd FROM git_repo_cwd_aliases WHERE cwd = ?",
                    arguments: [aliasPath]
                ),
                realPath
            )
        }
    }

    // End-to-end with the real git probe against a throwaway repo: proves the
    // shell path resolves a top-level, reads the last commit, and detects dirt.
    func testProbeGitReadsRealRepository() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path] + args
            p.environment = ProcessInfo.processInfo.environment
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " "))")
        }
        try git(["init", "-q"])
        try git(["config", "user.email", "t@t.t"])
        try git(["config", "user.name", "t"])
        try "hello".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", "initial | commit"])
        // Leave an untracked file so untrackedCount > 0.
        try "x".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let info = try XCTUnwrap(RepoDiscovery.probeGit(repo.path))
        // git resolves /var -> /private/var on macOS; compare by basename.
        XCTAssertEqual((info.path as NSString).lastPathComponent, repo.lastPathComponent)
        XCTAssertEqual(info.name, repo.lastPathComponent)
        XCTAssertEqual(info.untrackedCount, 1)
        XCTAssertEqual(info.lastCommitMsg, "initial | commit")
        XCTAssertNotNil(info.lastCommitHash)
        XCTAssertEqual(info.unpushedCount, 0) // no upstream

        XCTAssertNil(RepoDiscovery.probeGit("/tmp/definitely-not-a-repo-\(UUID().uuidString)"))
    }

    func testRunGitReturnsNilWhenCommandExceedsTimeout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-discovery-timeout-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeGit = bin.appendingPathComponent("git")
        try """
        #!/bin/sh
        /bin/sleep 5
        """.write(to: fakeGit, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(fakeGit.path, 0o755), 0)

        let started = Date()
        let output = RepoDiscovery.runGit(
            ["status"],
            cwd: work.path,
            timeoutSeconds: 0.5,
            environment: ["PATH": bin.path]
        )

        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testRunGitDrainsLargeOutputWithoutDeadlock() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-large-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path] + args
            p.environment = ProcessInfo.processInfo.environment
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " "))")
        }
        try git(["init", "-q"])
        try git(["config", "user.email", "t@t.t"])
        try git(["config", "user.name", "t"])
        // A blob much larger than the ~64KB OS pipe buffer. The old runGit read
        // stdout only AFTER the process exited, so git blocked on write() once
        // the buffer filled, the termination handler never fired, and runGit
        // hit its timeout and returned nil (the repo was silently skipped).
        let big = String(repeating: "abcdefABCDEF0123456789\n", count: 8000) // ~180KB
        try big.write(to: repo.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", "big"])

        let output = RepoDiscovery.runGit(["show", "HEAD:big.txt"], cwd: repo.path, timeoutSeconds: 5)
        let unwrapped = try XCTUnwrap(
            output,
            "runGit must drain >64KB output concurrently instead of deadlocking to a timeout"
        )
        XCTAssertGreaterThan(unwrapped.utf8.count, 64 * 1024)
    }

    func testProbeRepositoriesDetailedReportsFailedCwds_repro() {
        let candidates = [
            GitRepoCandidate(cwd: "/repo/ok", sessionCount: 2),
            GitRepoCandidate(cwd: "/repo/missing", sessionCount: 1),
        ]
        let batch = RepoDiscovery.probeRepositoriesDetailed(candidates) { cwd in
            guard cwd == "/repo/ok" else { return nil }
            return GitRepoProbe(
                path: "/repo/ok",
                name: "ok",
                branch: "main",
                dirtyCount: 0,
                untrackedCount: 0,
                unpushedCount: 0,
                lastCommitHash: "abc",
                lastCommitMsg: "hi",
                lastCommitAt: "2026-08-13T00:00:00Z"
            )
        }
        XCTAssertEqual(batch.failedCwds, ["/repo/missing"])
        XCTAssertEqual(batch.entries.map(\.probe.path), ["/repo/ok"])
        XCTAssertEqual(batch.entries.map(\.sessionCount), [2])
        XCTAssertEqual(
            RepoDiscovery.probeRepositories(candidates) { cwd in
                cwd == "/repo/ok" ? batch.entries[0].probe : nil
            }.map(\.probe.path),
            ["/repo/ok"]
        )
    }

    private func insertSession(_ db: Database, id: String, cwd: String) throws {
        try db.execute(
            sql: """
            INSERT INTO sessions(
                id, source, start_time, end_time, cwd, file_path,
                instruction_count, human_turn_count
            )
            VALUES (?, 'codex', '2026-05-23T10:00:00.000Z', '2026-05-23T11:00:00.000Z', ?, ?, 2, 2)
            """,
            arguments: [id, cwd, "/tmp/\(id).jsonl"]
        )
    }
}
