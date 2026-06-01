import XCTest
@testable import Engram

final class TodayWorkbenchTests: XCTestCase {
    func testCopyableResumeCommandUsesShellSafeRenderer() throws {
        let response = EngramServiceResumeCommandResponse(
            tool: "codex",
            command: "/usr/local/bin/codex",
            args: ["--resume", "abc; touch /tmp/pwned", "$(whoami)"],
            cwd: "/tmp/project's dir"
        )

        let command = try TodayResumeCommand.copyableCommand(from: response)

        XCTAssertEqual(
            command,
            "cd '/tmp/project'\\''s dir' && /usr/local/bin/codex --resume 'abc; touch /tmp/pwned' '$(whoami)'"
        )
    }

    func testHandledFollowUpsPersistAsAStableSessionIdSet() {
        let suiteName = "TodayWorkbenchTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var store = TodayHandledFollowUps(defaults: defaults)
        XCTAssertFalse(store.isHandled("follow-up-1"))

        store.markHandled("follow-up-1")
        store.markHandled("follow-up-2")
        store.markHandled("follow-up-1")

        let reloaded = TodayHandledFollowUps(defaults: defaults)
        XCTAssertTrue(reloaded.isHandled("follow-up-1"))
        XCTAssertTrue(reloaded.isHandled("follow-up-2"))
        XCTAssertEqual(reloaded.handledIds.count, 2)
    }

    func testContinueRankingPrefersResumableSessionsWithAgentContext() {
        let recent = [
            makeSession(id: "newer-plain", source: "unknown", startTime: "2026-06-01T10:00:00Z"),
            makeSession(id: "older-agent", source: "codex", startTime: "2026-06-01T09:00:00Z")
        ]

        let ranked = TodayWorkbenchRanking.continueSessions(
            from: recent,
            confirmedCounts: ["older-agent": 2],
            suggestedCounts: [:],
            limit: 2
        )

        XCTAssertEqual(ranked.map(\.id), ["older-agent", "newer-plain"])
    }

    func testProjectWarningPrefersMigrationThenRepoState() {
        let group = DatabaseManager.ProjectGroup(
            id: "/work/Engram",
            project: "/work/Engram",
            sessionCount: 3,
            lastActive: "2026-06-01T08:00:00Z",
            sessions: []
        )
        let migration = EngramServiceMigrationLogEntry(
            id: "mig-1",
            oldPath: "/old/Engram",
            newPath: "/work/Engram",
            oldBasename: "Engram",
            newBasename: "Engram",
            state: "committed",
            startedAt: "2026-06-01T07:00:00Z",
            finishedAt: "2026-06-01T07:01:00Z",
            archived: false,
            auditNote: nil,
            actor: "test",
            detail: nil
        )
        let repo = GitRepo(
            path: "/work/Engram",
            name: "Engram",
            branch: "main",
            dirtyCount: 2,
            untrackedCount: 1,
            unpushedCount: 4,
            lastCommitHash: nil,
            lastCommitMsg: nil,
            lastCommitAt: nil,
            sessionCount: 3,
            probedAt: nil
        )

        XCTAssertEqual(
            TodayProjectWarning.warning(for: group, repos: [repo], migrations: [migration]),
            "Migrated"
        )
        XCTAssertEqual(
            TodayProjectWarning.warning(for: group, repos: [repo], migrations: []),
            "3 changed · 4 unpushed"
        )
    }

    private func makeSession(
        id: String,
        source: String,
        startTime: String,
        cwd: String = "/work/Engram"
    ) -> Session {
        Session(
            id: id,
            source: source,
            startTime: startTime,
            endTime: nil,
            cwd: cwd,
            project: "Engram",
            model: nil,
            messageCount: 2,
            userMessageCount: 1,
            assistantMessageCount: 1,
            systemMessageCount: 0,
            summary: nil,
            filePath: "/tmp/\(id).jsonl",
            sourceLocator: nil,
            sizeBytes: 100,
            indexedAt: startTime,
            agentRole: nil,
            hiddenAt: nil,
            customName: nil,
            tier: nil,
            toolMessageCount: 0,
            generatedTitle: id,
            parentSessionId: nil,
            suggestedParentId: nil,
            linkSource: nil,
            qualityScore: nil
        )
    }
}
