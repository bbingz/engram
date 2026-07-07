// macos/EngramTests/AgentsViewTests.swift
import XCTest
import GRDB
@testable import Engram

/// WP07: covers the new pending-suggestion inbox read query plus source-inspection
/// guards locking the AgentsView/LinkParentPicker wiring (confirm/dismiss/set-parent,
/// grouping, live refresh) so it cannot silently regress to the old flat list.
final class AgentsViewTests: XCTestCase {
    var db: DatabaseManager!
    var dbPath: String!

    @MainActor
    override func setUpWithError() throws {
        let tempDir = FileManager.default.temporaryDirectory
        dbPath = tempDir.appendingPathComponent("test-\(UUID().uuidString).sqlite").path
        try createSessionsTable(at: dbPath)
        db = DatabaseManager(path: dbPath)
        try db.open()
    }

    @MainActor
    override func tearDownWithError() throws {
        db = nil
        cleanupTempDatabase(at: dbPath)
    }

    // Set parent/suggested links via an inline write — NOT the private
    // DatabaseManagerTests.setParentLinks helper (not callable here).
    private func setLink(sessionId: String, parentId: String?, suggestedParentId: String?) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET parent_session_id = ?, suggested_parent_id = ? WHERE id = ?",
                arguments: [parentId, suggestedParentId, sessionId]
            )
        }
    }

    private func setAmbiguousSuggestion(sessionId: String, candidatesJSON: String) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(
                sql: """
                    UPDATE sessions
                    SET suggestion_status = 'ambiguous',
                        suggestion_candidates = ?,
                        suggested_parent_id = NULL,
                        parent_session_id = NULL
                    WHERE id = ?
                """,
                arguments: [candidatesJSON, sessionId]
            )
        }
    }

    // MARK: - pendingSuggestionSessions read query

    func testPendingSuggestionsReturnsOnlyUnconfirmedTopLevel() throws {
        try insertTestSession(at: dbPath, id: "parent")
        try insertTestSession(at: dbPath, id: "sug")
        try insertTestSession(at: dbPath, id: "conf")
        try insertTestSession(at: dbPath, id: "unrelated")
        // "sug" awaits review; "conf" is already a confirmed child; "unrelated"
        // is a plain top-level session with no suggestion.
        try setLink(sessionId: "sug", parentId: nil, suggestedParentId: "parent")
        try setLink(sessionId: "conf", parentId: "parent", suggestedParentId: "parent")

        XCTAssertEqual(try db.pendingSuggestionSessions().map(\.id), ["sug"])
    }

    func testPendingSuggestionsExcludesHiddenByDefault() throws {
        try insertTestSession(at: dbPath, id: "parent")
        try insertTestSession(at: dbPath, id: "sug", hiddenAt: "2026-03-20T12:00:00Z")
        try setLink(sessionId: "sug", parentId: nil, suggestedParentId: "parent")

        XCTAssertEqual(try db.pendingSuggestionSessions().map(\.id), [])
        XCTAssertEqual(try db.pendingSuggestionSessions(includeHidden: true).map(\.id), ["sug"])
    }

    func testPendingSuggestionsHonorsLimit() throws {
        try insertTestSession(at: dbPath, id: "parent")
        for i in 0..<3 {
            try insertTestSession(at: dbPath, id: "sug-\(i)", startTime: "2026-03-2\(i)T10:00:00Z")
            try setLink(sessionId: "sug-\(i)", parentId: nil, suggestedParentId: "parent")
        }
        XCTAssertEqual(try db.pendingSuggestionSessions(limit: 2).count, 2)
    }

    func testAmbiguousSuggestionSessionsDecodeCandidatesAndResolveTitles() throws {
        try insertTestSession(at: dbPath, id: "parent-a", customName: "Alpha parent")
        try insertTestSession(at: dbPath, id: "parent-b", generatedTitle: "Beta parent")
        try insertTestSession(at: dbPath, id: "agent", source: "codex", summary: "Agent needing review")
        try setAmbiguousSuggestion(
            sessionId: "agent",
            candidatesJSON: """
            [{"id":"parent-b","score":0.95},{"id":"missing-parent","score":0.91},{"id":"parent-a","score":0.9}]
            """
        )

        let rows = try db.ambiguousSuggestionSessions()

        XCTAssertEqual(rows.map(\.session.id), ["agent"])
        XCTAssertEqual(rows[0].candidates.map(\.id), ["parent-b", "missing-parent", "parent-a"])
        XCTAssertEqual(rows[0].candidates.map(\.displayTitle), ["Beta parent", "missing-parent", "Alpha parent"])
        XCTAssertEqual(rows[0].candidates.map(\.score), [0.95, 0.91, 0.9])
    }

    // MARK: - setParentSession success/error branches via the mock client

    func testMockSetParentSessionSuccessAndFailureSurface() async throws {
        let ok = MockEngramServiceClient(
            setParentSession: EngramServiceLinkResponse(ok: true, error: nil)
        )
        let okResponse = try await ok.setParentSession(sessionId: "sug", parentId: "parent")
        XCTAssertTrue(okResponse.ok)

        let failing = MockEngramServiceClient(
            setParentSession: EngramServiceLinkResponse(ok: false, error: "depth exceeded")
        )
        let failResponse = try await failing.setParentSession(sessionId: "sug", parentId: "parent")
        XCTAssertFalse(failResponse.ok)
        XCTAssertEqual(failResponse.error, "depth exceeded")
    }

    // MARK: - Source-inspection guards

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testAgentsViewWiresGroupingAndActions() throws {
        let s = try source("macos/Engram/Views/Pages/AgentsView.swift")
        XCTAssertTrue(s.contains("ExpandableSessionCard"), "groups must render ExpandableSessionCard")
        XCTAssertFalse(s.contains("SessionCard(session:"), "flat read-only SessionCard list must be gone")
        XCTAssertTrue(s.contains("serviceClient.confirmSuggestion"))
        XCTAssertTrue(s.contains("serviceClient.dismissSuggestion"))
        XCTAssertTrue(s.contains("serviceClient.dismissAmbiguousSuggestion"))
        XCTAssertTrue(s.contains("serviceClient.setParentSession"))
        XCTAssertTrue(s.contains("pendingSuggestionSessions"))
        XCTAssertTrue(s.contains("ambiguousSuggestionSessions"))
        XCTAssertTrue(s.contains("Ambiguous"))
        XCTAssertTrue(s.contains(".task(id: serviceStatusStore.totalSessions)"),
                      "must live-refresh on indexing progress")
        // Set-parent lives on the pending-suggestion inbox rows (not on the
        // grouping ExpandableSessionCard — that invariant is checked separately
        // by testExpandableSessionCardHasNoSetParentHook).
        XCTAssertTrue(s.contains("onSetParent"),
                      "pending-suggestion inbox rows must offer a Set-parent action")
    }

    func testLinkParentPickerCallsSetParentOffMain() throws {
        let s = try source("macos/Engram/Views/LinkParentPicker.swift")
        XCTAssertTrue(s.contains("serviceClient.setParentSession"))
        XCTAssertTrue(s.contains("Task.detached"), "candidate parents must load off the main thread")
    }

    func testExpandableSessionCardHasNoSetParentHook() throws {
        // Proves WP07 did not edit WP01's card to add a Set-parent affordance.
        let s = try source("macos/Engram/Components/ExpandableSessionCard.swift")
        XCTAssertFalse(s.contains("onSetParent"))
    }
}
