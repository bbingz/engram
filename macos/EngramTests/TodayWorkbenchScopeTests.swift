import XCTest
@testable import Engram

/// Locks the Today Workbench / SessionDetail / AISettings review fixes:
/// - Follow-up scoping (recent window + top-level only + narrowed keywords)
/// - Relative-time dual ISO parsing (fractional + whole-second)
/// - System-prompt / agent-comm visibility gating in the transcript
/// - Off-main transcript build + AISettings persistence decoupled from disclosure
final class TodayWorkbenchScopeTests: XCTestCase {

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
        // Badge clamps to this; ranking can return up to 8.
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
        XCTAssertFalse(
            s.contains("let result = IndexedMessage.build(from: messages)"),
            "transcript classification must not run on the main actor (perf finding)"
        )
        XCTAssertTrue(
            s.contains("IndexedMessage.build(from: snapshot)"),
            "transcript must be built off-main inside the detached rebuild task"
        )
        // isFavorite must be read off the main actor.
        XCTAssertFalse(
            s.contains("isFavorite = (try? db.isFavorite(sessionId: session.id)) ?? false"),
            "isFavorite must not be read synchronously on the main actor"
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
}
