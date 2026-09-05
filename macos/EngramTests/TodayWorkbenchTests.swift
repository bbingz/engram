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

    func testCopyableResumeCommandIncludesContextPrimer() throws {
        let response = EngramServiceResumeCommandResponse(
            tool: "codex",
            command: "codex",
            args: ["--resume", "session-1"],
            cwd: "/repo",
            contextPrimer: "Resume context from Engram archive"
        )

        let command = try TodayResumeCommand.copyableCommand(from: response)

        XCTAssertTrue(command.contains("# Engram context primer:"))
        XCTAssertTrue(command.contains("# Resume context from Engram archive"))
    }

    func testClipboardItemFallsBackToContextPrimerWhenResumeCommandErrors() throws {
        let response = EngramServiceResumeCommandResponse(
            contextPrimer: """
            Resume context from Engram archive:
            - restore the current migration plan
            """,
            error: "codex CLI not found",
            hint: "Install Codex"
        )

        let item = try TodayResumeCommand.copyableClipboardItem(from: response)

        XCTAssertEqual(item.text, """
        Resume context from Engram archive:
        - restore the current migration plan
        """)
        XCTAssertEqual(item.message, String(localized: "Context primer copied"))
    }

    func testResumeClipboardSuccessMessagesAreInStringCatalog() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Engram/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        XCTAssertNotNil(strings["Resume command copied"])
        XCTAssertNotNil(strings["Context primer copied"])
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

    func testHomeInjectsHermeticAppStorageIntoHandledFollowUps_repro() throws {
        let macos = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let support = try String(
            contentsOf: macos.appendingPathComponent("Engram/Views/Pages/TodayWorkbenchSupport.swift"),
            encoding: .utf8
        )
        let home = try String(
            contentsOf: macos.appendingPathComponent("Engram/Views/Pages/HomeView.swift"),
            encoding: .utf8
        )
        let main = try String(
            contentsOf: macos.appendingPathComponent("Engram/Views/MainWindowView.swift"),
            encoding: .utf8
        )
        let menu = try String(
            contentsOf: macos.appendingPathComponent("Engram/MenuBarController.swift"),
            encoding: .utf8
        )

        // docs/invariants.md #6: UI-test app storage must stay inside its sandbox suite.
        XCTAssertFalse(support.contains("UserDefaults = .standard"))
        XCTAssertTrue(home.contains("init(appStorage: UserDefaults)"))
        XCTAssertTrue(home.contains("State(initialValue: TodayHandledFollowUps(defaults: appStorage))"))
        XCTAssertTrue(main.contains("HomeView(appStorage: appStorage)"))
        XCTAssertTrue(menu.contains("appStorage: appStorage"))
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
            String(localized: "Migrated")
        )
        XCTAssertEqual(
            TodayProjectWarning.warning(for: group, repos: [repo], migrations: []),
            [
                String.localizedStringWithFormat(String(localized: "%lld changed"), 3),
                String.localizedStringWithFormat(String(localized: "%lld unpushed"), 4),
            ].joined(separator: " · ")
        )
    }

    func testProjectWarningMatchesDarwinRealpathAliases_repro() {
        let suffix = "engram-warning-\(UUID().uuidString)"
        let group = DatabaseManager.ProjectGroup(
            id: "/tmp/\(suffix)",
            project: "/tmp/\(suffix)",
            sessionCount: 1,
            lastActive: "2026-08-24T12:00:00Z",
            sessions: [makeSession(
                id: "realpath-session",
                source: "codex",
                startTime: "2026-08-24T12:00:00Z",
                cwd: "/tmp/\(suffix)/child"
            )]
        )
        let repo = GitRepo(
            path: "/private/tmp/\(suffix)",
            name: "canonical-repo",
            branch: "main",
            dirtyCount: 1,
            untrackedCount: 0,
            unpushedCount: 0,
            lastCommitHash: nil,
            lastCommitMsg: nil,
            lastCommitAt: nil,
            sessionCount: 1,
            probedAt: nil
        )

        XCTAssertEqual(
            TodayProjectWarning.warning(for: group, repos: [repo], migrations: []),
            String.localizedStringWithFormat(String(localized: "%lld changed"), 1)
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
