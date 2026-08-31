import XCTest
import GRDB
@testable import Engram

/// Locks the Today Workbench / SessionDetail / AISettings review fixes:
/// - Follow-up scoping (recent window + top-level only + narrowed keywords)
/// - Relative-time dual ISO parsing (fractional + whole-second)
/// - System-prompt / agent-comm visibility gating in the transcript
/// - Off-main transcript build + AISettings persistence decoupled from disclosure
final class TodayWorkbenchScopeTests: XCTestCase {
    func testSessionDetailRejectsStaleParentAndRelatedLoads_repro() {
        XCTAssertTrue(
            SessionDetailView.shouldApplySessionLoad(
                resultLoadToken: "current",
                currentLoadToken: "current"
            )
        )
        XCTAssertFalse(
            SessionDetailView.shouldApplySessionLoad(
                resultLoadToken: "previous",
                currentLoadToken: "current"
            )
        )
        XCTAssertFalse(
            SessionDetailView.shouldApplySessionLoad(
                resultLoadToken: "current",
                currentLoadToken: "current",
                isCancelled: true
            )
        )
    }

    // session-detail-id-regress-1 (docs/followups.md Round-12 parked): the
    // favorite toggle's success branch must bump `favoriteLoadGeneration` so a
    // slower in-flight initial favorite read cannot land after the mutation and
    // clobber it with the pre-toggle value.
    func testFavoriteToggleInvalidatesPendingRead_repro() throws {
        let detail = try source("macos/Engram/Views/SessionDetailView.swift")
        let toggleStart = try XCTUnwrap(detail.range(of: "onToggleFavorite: {"))
        let toggleEnd = try XCTUnwrap(
            detail.range(of: "onCopyAll:", range: toggleStart.upperBound..<detail.endIndex)
        )
        let toggle = detail[toggleStart.lowerBound..<toggleEnd.lowerBound]
        let apply = try XCTUnwrap(toggle.range(of: "isFavorite = next"))
        let invalidate = try XCTUnwrap(
            toggle.range(of: "favoriteLoadGeneration = UUID()"),
            "toggle must invalidate the pending favorite-read generation"
        )
        XCTAssertLessThan(apply.lowerBound, invalidate.lowerBound)
    }

    func testSessionDetailAResultCannotApplyAfterSwitchToB_repro() {
        let capturedSessionId = "A"
        var displayedSessionId: String? = "A"
        XCTAssertTrue(
            SessionDetailView.shouldApplySessionResult(
                capturedSessionId: capturedSessionId,
                displayedSessionId: displayedSessionId,
                resultLoadToken: "A:load",
                currentLoadToken: "A:load"
            )
        )

        displayedSessionId = "B"
        XCTAssertFalse(
            SessionDetailView.shouldApplySessionResult(
                capturedSessionId: capturedSessionId,
                displayedSessionId: displayedSessionId,
                resultLoadToken: "A:load",
                currentLoadToken: "A:load"
            )
        )
        XCTAssertFalse(
            SessionDetailView.shouldApplySessionMutation(
                capturedSessionId: capturedSessionId,
                displayedSessionId: displayedSessionId
            )
        )
    }

    func testSessionDetailTrustsFreshNilParentLinks_repro() {
        let fresh = makeSession(id: "child", startTime: "2026-08-23T00:00:00Z")
        let links = SessionDetailView.effectiveParentLinkIDs(
            freshSession: fresh,
            snapshotParentId: "stale-parent",
            snapshotSuggestedId: "stale-suggestion"
        )

        XCTAssertNil(links.parentId)
        XCTAssertNil(links.suggestedId)
    }

    func testMainWindowKeepsDetailIdentityStableForSameSessionOpen_repro() throws {
        let source = try source("macos/Engram/Views/MainWindowView.swift")
        XCTAssertFalse(source.contains("@State private var sessionPresentationId"))
        XCTAssertTrue(source.contains(".id(session.id)"))
        XCTAssertTrue(source.contains("private func applyOpenSession(_ box: SessionBox)"))
    }

    func testSessionDetailTracksMutationsWithoutCancellingInFlightRPCs_repro() throws {
        let source = try source("macos/Engram/Views/SessionDetailView.swift")
        XCTAssertTrue(source.contains("@State private var parentMutationTask: Task<Void, Never>?"))
        XCTAssertFalse(
            source.contains("parentMutationTask?.cancel()"),
            "session switches must not close the Unix-socket RPC before the service applies the write"
        )
        for function in [
            "private func removeRelated(",
            "private func confirmSuggestedChild(",
            "private func confirmSuggestedParent(",
            "private func dismissSuggestedParent(",
            "private func unlinkParent(",
            "private func dismissSuggestedChild(",
        ] {
            let start = try XCTUnwrap(source.range(of: function))
            let tail = source[start.lowerBound...]
            let end = tail.dropFirst().range(of: "\n    private func ")?.lowerBound ?? tail.endIndex
            XCTAssertTrue(
                tail[..<end].contains("parentMutationTask = Task"),
                "\(function) must keep its write task alive independently of follow-up loads"
            )
        }
    }

    func testProjectWorkTimelineUsesInjectedClockForReadsTitlesAndLabels_repro() throws {
        let timeline = try source("macos/Engram/Components/ProjectWorkTimeline.swift")
        XCTAssertTrue(timeline.contains("@Environment(\\.engramFixedDate)"))
        XCTAssertTrue(timeline.contains("now: now"))
        XCTAssertTrue(timeline.contains("project: project, now: now"))
        XCTAssertTrue(timeline.contains("dateRange(item, now: now)"))

        let projects = try source("macos/Engram/Views/Pages/ProjectsView.swift")
        XCTAssertTrue(projects.contains("@Environment(\\.engramFixedDate)"))
        XCTAssertTrue(projects.contains("let now = fixedDate ?? Date()"))
    }


    // MARK: - Fixtures

    private func makeSession(
        id: String,
        startTime: String,
        parentSessionId: String? = nil,
        suggestedParentId: String? = nil
    ) -> Session {
        Session(
            id: id,
            source: "claude-code",
            startTime: startTime,
            endTime: nil,
            cwd: "/work/Engram",
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
            parentSessionId: parentSessionId,
            suggestedParentId: suggestedParentId,
            linkSource: nil,
            qualityScore: nil
        )
    }

    // MARK: - Follow-up scoping (finding #1)

    func testFollowUpQueriesDropBroadKeywords() {
        // "review"/"todo" matched almost any transcript — must not be present.
        XCTAssertFalse(TodayFollowUps.queries.contains("review"))
        XCTAssertFalse(TodayFollowUps.queries.contains("todo"))
        XCTAssertTrue(TodayFollowUps.queries.contains("follow-up"))
        XCTAssertTrue(TodayFollowUps.queries.contains("deferred"))
    }

    func testFollowUpEligibilityKeepsRecentTopLevelSession() {
        let now = Date()
        let recent = makeSession(
            id: "recent",
            startTime: ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        )
        XCTAssertTrue(TodayFollowUps.isEligible(recent, handledIds: [], now: now))
    }

    func testFollowUpEligibilityRejectsOldSession() {
        let now = Date()
        let old = makeSession(
            id: "old",
            startTime: ISO8601DateFormatter().string(from: now.addingTimeInterval(-100 * 3600))
        )
        XCTAssertFalse(TodayFollowUps.isEligible(old, handledIds: [], now: now))
    }

    func testFollowUpEligibilityRejectsConfirmedAndSuggestedChildren() {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let confirmedChild = makeSession(id: "c", startTime: ts, parentSessionId: "p")
        let suggestedChild = makeSession(id: "s", startTime: ts, suggestedParentId: "p")
        XCTAssertFalse(TodayFollowUps.isEligible(confirmedChild, handledIds: [], now: now))
        XCTAssertFalse(TodayFollowUps.isEligible(suggestedChild, handledIds: [], now: now))
    }

    func testFollowUpEligibilityRejectsHandled() {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let s = makeSession(id: "handled", startTime: ts)
        XCTAssertFalse(TodayFollowUps.isEligible(s, handledIds: ["handled"], now: now))
    }

    func testFollowUpEligibilityParsesWholeSecondTimestamp() {
        // No fractional seconds — must still parse and pass when recent.
        let now = ISO8601DateFormatter().date(from: "2026-06-01T10:00:30Z")!
        let s = makeSession(id: "plain", startTime: "2026-06-01T10:00:00Z")
        XCTAssertTrue(TodayFollowUps.isEligible(s, handledIds: [], now: now))
    }

    func testFollowUpSearchPushesRecencyWindowIntoDatabaseQuery() throws {
        let s = try source("macos/Engram/Views/Pages/HomeView.swift")
        let start = try XCTUnwrap(s.range(of: "private func loadTodayFollowUps"))
        let end = try XCTUnwrap(s.range(of: "/// Scoping rules for the Today \"Follow-ups\" panel."))
        let loader = String(s[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(loader.contains("now.addingTimeInterval(-TodayFollowUps.recencyWindow)"))
        XCTAssertTrue(loader.contains("db.todayFollowUpSessions("))
        XCTAssertTrue(loader.contains("startedSince: since"))
    }

    func testFollowUpLoaderUsesSQLScopedReadBeforeLimit_repro() throws {
        let s = try source("macos/Engram/Views/Pages/HomeView.swift")
        let start = try XCTUnwrap(s.range(of: "private func loadTodayFollowUps"))
        let end = try XCTUnwrap(s.range(of: "/// Scoping rules for the Today \"Follow-ups\" panel."))
        let loader = String(s[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(
            loader.contains("db.todayFollowUpSessions("),
            "top-level, recent, unhandled eligibility must be applied in SQL before LIMIT"
        )
        XCTAssertFalse(
            loader.contains("db.searchWithSnippets"),
            "a small per-query FTS page can be exhausted by children before post-filtering"
        )
    }

    func testFollowUpSQLScopePreventsChildStarvation() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("followups-\(UUID().uuidString).sqlite").path
        try createSessionsTable(at: path)
        var manager: DatabaseManager? = DatabaseManager(path: path)
        defer {
            manager = nil
            cleanupTempDatabase(at: path)
        }
        try manager?.open()
        let now = ISO8601DateFormatter().date(from: "2026-08-22T10:00:00Z")!
        let queue = try DatabaseQueue(path: path)

        for index in 0..<8 {
            let id = "child-\(index)"
            try insertTestSession(
                at: path,
                id: id,
                startTime: "2026-08-22T09:\(String(format: "%02d", index)):00Z"
            )
            try insertFTSContent(at: path, sessionId: id, content: "follow-up child")
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE sessions SET parent_session_id = 'parent' WHERE id = ?",
                    arguments: [id]
                )
            }
        }
        try insertTestSession(
            at: path,
            id: "eligible",
            startTime: "2026-08-22T08:00:00Z",
            endTime: "2026-08-22T08:30:00Z"
        )
        try insertFTSContent(at: path, sessionId: "eligible", content: "follow-up root")

        let since = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(-TodayFollowUps.recencyWindow)
        )
        XCTAssertEqual(
            try manager?.todayFollowUpSessions(
                queries: ["follow-up"],
                startedSince: since,
                excluding: [],
                limit: 1
            ).map(\.id),
            ["eligible"]
        )
    }

    func testFollowUpSQLScopeUsesSessionActivityTime_repro() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("followups-activity-\(UUID().uuidString).sqlite").path
        try createSessionsTable(at: path)
        var manager: DatabaseManager? = DatabaseManager(path: path)
        defer {
            manager = nil
            cleanupTempDatabase(at: path)
        }
        try manager?.open()
        try insertTestSession(at: path, id: "overnight-follow-up", startTime: "2026-08-18T08:00:00Z")
        try insertFTSContent(at: path, sessionId: "overnight-follow-up", content: "remaining follow-up")
        try DatabaseQueue(path: path).write { db in
            try db.execute(
                sql: "UPDATE sessions SET end_time = '2026-08-23T09:00:00Z' WHERE id = 'overnight-follow-up'"
            )
        }

        let sessions = try manager?.todayFollowUpSessions(
            queries: ["follow-up"],
            startedSince: "2026-08-23T00:00:00Z",
            excluding: [],
            limit: 5
        )
        XCTAssertEqual(sessions?.map(\.id), ["overnight-follow-up"])
    }

    // MARK: - Relative time dual parsing (finding #3)

    func testRelativeTimeParsesWholeSecondTimestamp() {
        let now = ISO8601DateFormatter().date(from: "2026-06-01T10:30:00Z")!
        // Whole-second timestamp used to render blank under a fractional-only formatter.
        XCTAssertEqual(TodayRelativeTime.format("2026-06-01T10:00:00Z", now: now), "30m ago")
    }

    func testRelativeTimeParsesFractionalTimestamp() {
        let now = ISO8601DateFormatter().date(from: "2026-06-01T12:00:00Z")!
        XCTAssertEqual(TodayRelativeTime.format("2026-06-01T10:00:00.000Z", now: now), "2h ago")
    }

    func testRelativeTimeNowAndBlankFallback() {
        let now = ISO8601DateFormatter().date(from: "2026-06-01T10:00:30Z")!
        XCTAssertEqual(TodayRelativeTime.format("2026-06-01T10:00:00Z", now: now), "now")
        XCTAssertEqual(TodayRelativeTime.format("not-a-date", now: now), "")
    }

    // MARK: - Panel badge matches render (finding #2)

    func testTodayPanelRowLimitMatchesRenderedRows() {
        // Badge clamps to this for Continue / Follow-ups / Changed Repos.
        XCTAssertEqual(todayPanelRowLimit, 5)
        XCTAssertEqual(min(8, todayPanelRowLimit), 5)
        XCTAssertEqual(min(3, todayPanelRowLimit), 3)
    }

    // MARK: - System-prompt / agent-comm toggle (finding #4)

    private func indexed(category: SystemCategory, type: MessageType) -> IndexedMessage {
        IndexedMessage(
            message: ChatMessage(role: "user", content: "x", systemCategory: category),
            messageType: type,
            typeIndex: 0
        )
    }

    func testSystemPromptVisibilityFollowsToggleNotTypeVisibility() {
        // .system defaults hidden in typeVisibility and has no chip; the toggle must win.
        let msg = indexed(category: .systemPrompt, type: .system)
        let hiddenTypes: [MessageType: Bool] = [.system: false]
        XCTAssertTrue(SessionDetailView.isMessageVisible(
            msg, typeVisibility: hiddenTypes, showSystemPrompts: true, showAgentComm: false
        ))
        XCTAssertFalse(SessionDetailView.isMessageVisible(
            msg, typeVisibility: hiddenTypes, showSystemPrompts: false, showAgentComm: false
        ))
    }

    func testAgentCommVisibilityFollowsToggle() {
        let msg = indexed(category: .agentComm, type: .toolCall)
        XCTAssertTrue(SessionDetailView.isMessageVisible(
            msg, typeVisibility: [.toolCall: true], showSystemPrompts: false, showAgentComm: true
        ))
        XCTAssertFalse(SessionDetailView.isMessageVisible(
            msg, typeVisibility: [.toolCall: true], showSystemPrompts: false, showAgentComm: false
        ))
    }

    func testRegularMessagesUseTypeVisibility() {
        let user = indexed(category: .none, type: .user)
        XCTAssertTrue(SessionDetailView.isMessageVisible(
            user, typeVisibility: [.user: true], showSystemPrompts: false, showAgentComm: false
        ))
        XCTAssertFalse(SessionDetailView.isMessageVisible(
            user, typeVisibility: [.user: false], showSystemPrompts: true, showAgentComm: true
        ))
    }

    // MARK: - Source guards (findings #5, #6)

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testSessionDetailBuildsTranscriptOffMain() throws {
        let s = try source("macos/Engram/Views/SessionDetailView.swift")
        // IndexedMessage.build must run inside the detached parse task, not on main.
        // Row 27 renamed the local snapshot, so pin where the call sits rather than
        // the identifier it is passed.
        let detachedStart = try XCTUnwrap(s.range(of: "let built = await Task.detached"))
        let detachedEnd = try XCTUnwrap(
            s.range(of: "}.value", range: detachedStart.upperBound..<s.endIndex)
        )
        let detachedBody = String(s[detachedStart.upperBound..<detachedEnd.lowerBound])
        XCTAssertTrue(
            detachedBody.contains("IndexedMessage.build(from:"),
            "transcript must be built off-main inside the detached rebuild task"
        )
        XCTAssertFalse(
            s.replacingOccurrences(of: detachedBody, with: "")
                .contains("IndexedMessage.build(from:"),
            "transcript classification must not run on the main actor (perf finding)"
        )
        // isFavorite must be read off the main actor.
        XCTAssertFalse(
            s.contains("isFavorite = (try? db.isFavorite(sessionId: session.id)) ?? false"),
            "isFavorite must not be read synchronously on the main actor"
        )
        XCTAssertTrue(
            s.contains("favoriteLoadGeneration = generation"),
            "favorite state must reset and tag each per-session load with a unique generation"
        )
        XCTAssertTrue(
            s.contains("if generation == favoriteLoadGeneration"),
            "stale favorite loads from a previous session must not overwrite the current detail view"
        )
    }

    // L32 / SESSION-DETAIL-FILTER-001: a fully loaded transcript may contain
    // 100k+ rows, so filter toggles must not scan that array on the main actor.
    func testSessionDetailFullFilterRunsOffMain_repro() throws {
        let s = try source("macos/Engram/Views/SessionDetailView.swift")
        let functionStart = try XCTUnwrap(s.range(of: "private func updateDisplayIndexed"))
        let functionEnd = try XCTUnwrap(
            s.range(
                of: "/// Decides whether an indexed message survives",
                options: [],
                range: functionStart.upperBound..<s.endIndex
            )
        )
        let functionSource = String(s[functionStart.lowerBound..<functionEnd.lowerBound])

        XCTAssertTrue(
            s.contains("@State private var displayFilterTask: Task<Void, Never>?"),
            "SessionDetailView must own and cancel the current full-filter task"
        )
        guard let detachedStart = functionSource.range(of: "let filterWork = Task.detached") else {
            XCTFail("full transcript visibility filtering must run in Task.detached")
            return
        }
        guard let detachedEnd = functionSource.range(
            of: "let filtered = await withTaskCancellationHandler",
            options: [],
            range: detachedStart.upperBound..<functionSource.endIndex
        ) else {
            XCTFail("the detached filter must be awaited through a cancellation handler")
            return
        }
        let detachedBody = String(functionSource[detachedStart.upperBound..<detachedEnd.lowerBound])
        XCTAssertTrue(detachedBody.contains("for idx in snapshot"))
        XCTAssertTrue(
            detachedBody.contains("Self.isMessageVisible("),
            "the O(N) visibility predicate loop must stay inside the detached task"
        )
        XCTAssertTrue(
            detachedBody.contains("guard !Task.isCancelled else { return nil }"),
            "a superseded detached scan must stop walking the loaded transcript"
        )
        XCTAssertFalse(
            functionSource.contains("displayIndexed = indexedMessages.filter"),
            "the full loaded set must not be filtered synchronously on the calling actor"
        )
        XCTAssertTrue(functionSource.contains("displayFilterTask?.cancel()"))
        XCTAssertTrue(functionSource.contains("filterWork.cancel()"))
        XCTAssertTrue(functionSource.contains("guard !Task.isCancelled"))
        XCTAssertTrue(
            functionSource.contains("displayFilterSessionId == sessionId"),
            "a completed filter must not publish into a different session"
        )

        // Preserve A3: Load more still filters only its newly indexed slice.
        XCTAssertTrue(functionSource.contains("appendedSlice.filter"))
        XCTAssertTrue(functionSource.contains("displayIndexed.append(contentsOf: visibleNew)"))
        let sessionTaskStart = try XCTUnwrap(s.range(of: ".task(id: session.id) {"))
        let sessionTaskEnd = try XCTUnwrap(
            s.range(of: ".onChange(of: typeVisibility)", range: sessionTaskStart.upperBound..<s.endIndex)
        )
        let sessionTask = String(s[sessionTaskStart.lowerBound..<sessionTaskEnd.lowerBound])
        XCTAssertTrue(
            sessionTask.contains("displayFilterTask?.cancel()"),
            "switching sessions must cancel the prior full transcript filter"
        )
        XCTAssertTrue(
            s.contains(".onDisappear {\n            displayFilterTask?.cancel(); displayFilterTask = nil"),
            "leaving the detail view must cancel the full transcript filter"
        )
    }

    // MARK: - Transcript paging (perf/transcript-paging)

    func testInitialTranscriptLimitGatesOnMessageCount() {
        // At/under the threshold → load the whole transcript (nil), unchanged.
        XCTAssertNil(SessionDetailView.initialTranscriptLimit(messageCount: 0))
        XCTAssertNil(SessionDetailView.initialTranscriptLimit(messageCount: 800))
        // Past the threshold → a bounded first page.
        XCTAssertEqual(SessionDetailView.initialTranscriptLimit(messageCount: 801), 500)
        XCTAssertEqual(SessionDetailView.initialTranscriptLimit(messageCount: 50_000), 500)
    }

    func testNextNavPositionClampsStaleIndex() {
        // A stale position (50) carried into a 10-match set must not index past the
        // end — the `direction < 0` branch used to trap (matching[49] on 10 items).
        XCTAssertEqual(SessionDetailView.nextNavPosition(current: 50, direction: -1, count: 10), 8)
        XCTAssertEqual(SessionDetailView.nextNavPosition(current: 50, direction: 1, count: 10), 0)
        // Normal wrap-around from the initial -1.
        XCTAssertEqual(SessionDetailView.nextNavPosition(current: -1, direction: 1, count: 10), 0)
        XCTAssertEqual(SessionDetailView.nextNavPosition(current: -1, direction: -1, count: 10), 9)
        // No matches → no navigation.
        XCTAssertNil(SessionDetailView.nextNavPosition(current: 0, direction: 1, count: 0))
    }

    func testNextFindMatchIndexClampsStaleIndex() {
        // Find navigation keeps its own position; shrinking the match set must
        // clamp a stale position before the previous-match branch indexes it.
        XCTAssertEqual(SessionDetailView.nextFindMatchIndex(current: 50, direction: -1, count: 10), 8)
        XCTAssertEqual(SessionDetailView.nextFindMatchIndex(current: 50, direction: 1, count: 10), 0)
        XCTAssertEqual(SessionDetailView.nextFindMatchIndex(current: -1, direction: 1, count: 10), 0)
        XCTAssertEqual(SessionDetailView.nextFindMatchIndex(current: -1, direction: -1, count: 10), 9)
        XCTAssertNil(SessionDetailView.nextFindMatchIndex(current: 0, direction: 1, count: 0))
    }

    func testDisplayedFindMatchIndexClampsStaleIndex() {
        XCTAssertEqual(SessionDetailView.displayedFindMatchIndex(current: 50, count: 10), 9)
        XCTAssertEqual(SessionDetailView.displayedFindMatchIndex(current: -1, count: 10), 0)
        XCTAssertNil(SessionDetailView.displayedFindMatchIndex(current: 0, count: 0))
    }

    func testHasMoreAfterLoadReflectsFilledPage() {
        // A full (limit == nil) load is always complete.
        XCTAssertFalse(SessionDetailView.hasMoreAfterLoad(returnedCount: 4, requestedLimit: nil))
        XCTAssertFalse(SessionDetailView.hasMoreAfterLoad(returnedCount: 0, requestedLimit: nil))
        // A page that came back full may have more behind it.
        XCTAssertTrue(SessionDetailView.hasMoreAfterLoad(returnedCount: 500, requestedLimit: 500))
        // A short page is the last one.
        XCTAssertFalse(SessionDetailView.hasMoreAfterLoad(returnedCount: 480, requestedLimit: 500))
        XCTAssertFalse(SessionDetailView.hasMoreAfterLoad(returnedCount: 0, requestedLimit: 500))
    }

    func testHasMoreAfterLoadPreservesTruncatedWholeRead_repro() {
        XCTAssertTrue(
            SessionDetailView.hasMoreAfterLoad(
                returnedCount: ParserLimits.default.maxMessages,
                requestedLimit: nil,
                truncated: true
            )
        )
    }

    func testLoadAllStopsOnFailureMetadataForFilledPage_repro() {
        XCTAssertTrue(
            SessionDetailView.shouldStopLoadAllPage(
                producedCount: 500,
                requestedLimit: 500,
                truncated: false,
                parseFailed: true
            )
        )
        XCTAssertTrue(
            SessionDetailView.shouldStopLoadAllPage(
                producedCount: 499,
                requestedLimit: 500,
                truncated: false,
                parseFailed: true
            )
        )
    }

    func testAISettingsPersistGenerationConfigUnconditionally() throws {
        let s = try source("macos/Engram/Views/Settings/AISettingsSection.swift")
        // Persistence must no longer be gated on the disclosure expansion flags.
        XCTAssertFalse(
            s.contains("if showCustomGeneration {"),
            "summaryMaxTokens/Temperature must persist regardless of disclosure expansion (data-integrity finding)"
        )
        XCTAssertFalse(
            s.contains("if showAdvancedGeneration {"),
            "sample/truncate settings must persist regardless of disclosure expansion (data-integrity finding)"
        )
        XCTAssertFalse(
            s.contains("settings.removeValue(forKey: \"summaryMaxTokens\")"),
            "collapsing a disclosure group must not delete saved generation settings"
        )
    }

    // Behavioral round-trip over the extracted pure transform (replaces the
    // source-scan-only coverage): the values the save path writes must restore
    // intact, and unrelated keys must survive — even in the collapse-then-edit
    // case (persistence is unconditional, so disclosure state is irrelevant).
    func testGenerationSettingsRoundTripPreservesCustomValues() {
        var settings: [String: Any] = ["aiModel": "gpt-x", "summaryLanguage": "zh"]
        let custom = AIGenerationSettings(
            maxTokens: 1234, temperature: 0.91, sampleFirst: 5, sampleLast: 7, truncateChars: 999
        )
        custom.write(into: &settings)
        XCTAssertEqual(AIGenerationSettings.read(from: settings), custom)
        // Unrelated keys are untouched by the generation-block transform.
        XCTAssertEqual(settings["aiModel"] as? String, "gpt-x")
        XCTAssertEqual(settings["summaryLanguage"] as? String, "zh")
    }

    func testGenerationSettingsReadFallsBackToDefaultsForMissingKeys() {
        XCTAssertEqual(AIGenerationSettings.read(from: [:]), AIGenerationSettings())
        // A mistyped value also falls back to the default rather than crashing.
        XCTAssertEqual(AIGenerationSettings.read(from: ["summaryMaxTokens": "oops"]).maxTokens, 200)
    }

    func testAISettingsDoesNotExposeUnimplementedAutoGenerationToggles() throws {
        let s = try source("macos/Engram/Views/Settings/AISettingsSection.swift")

        XCTAssertFalse(s.contains("Auto-generate summaries"))
        XCTAssertFalse(s.contains("Auto-generate titles"))
        XCTAssertFalse(s.contains("\"autoSummary\""))
        XCTAssertFalse(s.contains("\"autoSummaryCooldown\""))
        XCTAssertFalse(s.contains("\"autoSummaryMinMessages\""))
        XCTAssertFalse(s.contains("\"autoSummaryRefresh\""))
        XCTAssertFalse(s.contains("\"autoSummaryRefreshThreshold\""))
        XCTAssertFalse(s.contains("\"titleAutoGenerate\""))
    }
}
